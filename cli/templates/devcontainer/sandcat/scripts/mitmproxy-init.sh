#!/bin/sh
#
# Entrypoint wrapper for the mitmproxy container.
#
# Hands the TUN device node to mitmproxy's UID, then drops to that UID and
# execs mitmproxy with no capabilities at all.
#
# ── Why this exists ─────────────────────────────────────────────────────────
# Attaching to the TUN device passes two independent gates. CAP_NET_ADMIN is
# not one of them here — the netns container already created the device
# *persistent* and owned by PROXY_UID, and a persistent TUN can be reopened by
# its owner with no capabilities. What remains is plain file permission on the
# device node: /dev/net/tun is mode 0600 root:root, so PROXY_UID cannot open it.
#
# That cannot be fixed from the netns container. Containers share a network
# namespace here, not a mount namespace, so each gets its own /dev and its own
# device node. It has to happen in this container, which means starting as root
# for exactly as long as one chown takes.
#
# The chown is container-local: the engine creates the node in this container's
# own /dev, so the host's /dev/net/tun is untouched. (Under rootless podman the
# node is bind-mounted from the host instead, where an unprivileged mapped root
# cannot chown it — the chown fails outright rather than reaching the host.)
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

# Needs CAP_CHOWN, and nothing else: root already owns the node, so no
# DAC_OVERRIDE/FOWNER is involved.
chown "$PROXY_UID:$PROXY_GID" "$TUN_NODE"

# Fail loudly rather than let mitmproxy start and report an opaque
# "Failed to create TUN device / Permission denied" instead.
if [ "$(stat -c '%u' "$TUN_NODE")" != "$PROXY_UID" ]; then
    echo "Failed to hand $TUN_NODE to uid $PROXY_UID; refusing to start." >&2
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
