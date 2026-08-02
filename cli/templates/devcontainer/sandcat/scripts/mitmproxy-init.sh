#!/bin/sh
#
# Entrypoint wrapper for the mitmproxy container.
#
# Hands the TUN device node to mitmproxy's UID, then drops to that UID and
# execs mitmproxy with no capabilities at all.
#
# ── Why this exists ─────────────────────────────────────────────────────────
# Attaching to the TUN device passes independent gates. CAP_NET_ADMIN is not
# one of them here — the netns container already created the device
# *persistent* and owned by PROXY_UID, and a persistent TUN can be reopened by
# its owner with no capabilities. What remains is whatever stands between
# PROXY_UID and this container's own copy of the device node: DAC permission
# bits, and — on an SELinux-enforcing host — MAC policy on top of them.
#
# Neither can be fixed from the netns container. Containers share a network
# namespace here, not a mount namespace, so each gets its own /dev and its own
# device node. It has to happen in this container, which means starting as
# root for exactly as long as setup takes.
#
# The two gates need different handling, and neither is reliably fixable from
# here:
#
#   - DAC: under rootful engines the node is typically 0600 root:root, and
#     chown (CAP_CHOWN, no DAC_OVERRIDE/FOWNER needed since root already owns
#     it) fixes it. Under some rootless configurations the node is already
#     more permissive — chown is attempted regardless, but its failure isn't
#     itself fatal, because DAC may already be satisfied.
#   - MAC: on an SELinux-enforcing host, chr_file access to a device passed
#     through via `--device` needs the `container_use_devices` boolean
#     (default off) — a host-level setting this container cannot change, and
#     the boolean does not cover `setattr`, so chown can fail here for a
#     reason unrelated to whether the device is actually usable afterward.
#
# So chown's own exit status is not the signal to act on. What's checked
# instead, after attempting it, is the thing that actually matters: can
# PROXY_UID open the device at all. That is the same ambiguity
# netns-init.sh's check_tun_openable() resolves for the TUN clone device in
# the netns container — this is the same check, for the same reason, in the
# one place it also has to happen.
#
# ── What runs afterwards ────────────────────────────────────────────────────
# mitmproxy is the component that parses untrusted traffic, so it gets nothing:
# not root, not CAP_NET_ADMIN, no capabilities at all, and no way to regain any
# (--no-new-privs). The kill switch's egress exemption is keyed on PROXY_UID, so
# this must be the UID mitmproxy actually ends up running as.
#
# The image's own docker-entrypoint.sh is deliberately bypassed: its job is to
# drop privileges to the image's built-in user, which would undo the UID the
# kill switch was built around. We do the drop ourselves, to the right UID.
#
set -e

PROXY_UID="${SANDCAT_PROXY_UID:-1001}"
PROXY_GID="${SANDCAT_PROXY_GID:-1001}"
TUN_NODE="${SANDCAT_TUN_NODE:-/dev/net/tun}"
MITMPROXY_HOME="${SANDCAT_MITMPROXY_HOME:-/home/mitmproxy/.mitmproxy}"

if [ ! -e "$TUN_NODE" ]; then
    echo "$TUN_NODE is missing — the mitmproxy service needs the tun device" >&2
    echo "passed through (see 'devices:' in compose-proxy.yml)." >&2
    exit 1
fi

# Best-effort: on some hosts this is a no-op because DAC already permits
# PROXY_UID, and on an SELinux-enforcing host it fails regardless of whether
# DAC needed fixing, because `setattr` on a device node isn't something
# `container_use_devices` grants at all. Its exit status isn't checked —
# what's checked next is the thing that actually matters.
chown "$PROXY_UID:$PROXY_GID" "$TUN_NODE" 2>/dev/null || true

# The real check: can PROXY_UID actually open the device, regardless of why.
# Probed directly rather than inferred from chown's result or from stat'ing
# permission bits, because DAC bits alone can't tell you whether an
# SELinux-enforcing host is also going to deny the open.
if ! setpriv --reuid "$PROXY_UID" --regid "$PROXY_GID" --clear-groups \
        /bin/sh -c ': < "$1"' sandcat-tun-probe "$TUN_NODE" 2>/dev/null
then
    echo "uid $PROXY_UID cannot open $TUN_NODE; refusing to start." >&2
    echo "On an SELinux-enforcing host this is usually the" >&2
    echo "container_use_devices boolean (off by default) — a host-level" >&2
    echo "setting: sudo setsebool -P container_use_devices on" >&2
    echo "Otherwise, check the device's ownership and permission bits." >&2
    exit 1
fi

# setpriv changes the UID but not the environment, and this script starts as
# root — so without this, mitmproxy would keep HOME=/root and look for its
# config and CA under /root/.mitmproxy, which it can no longer read once
# dropped. It resolves options before anything else, so the failure is a
# startup crash rather than a degraded run.
HOME=$(dirname "$MITMPROXY_HOME")
export HOME

# Clearing the stale dns.conf sentinel happens *after* the privilege drop, as
# the UID that owns the config volume. Root cannot do it: cap_drop drops
# DAC_OVERRIDE along with everything else, and root has no write access to a
# directory owned by another UID without it.
#
# Why it has to happen at all: the config volume persists across restarts, so a
# dns.conf left by a previous run would satisfy the healthcheck immediately —
# letting dependents start against outdated settings (e.g. after editing
# `dns_servers`) before the addon has rewritten it.
exec setpriv \
    --reuid "$PROXY_UID" \
    --regid "$PROXY_GID" \
    --clear-groups \
    --inh-caps=-all \
    --no-new-privs \
    /bin/sh -c 'rm -f "$1" || exit 1; shift; exec "$@"' \
        sandcat-mitmproxy-init "$MITMPROXY_HOME/dns.conf" "$@"
