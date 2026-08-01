#!/bin/bash
#
# Entrypoint for the netns container: the container that owns the network
# namespace every other sandcat container joins.
#
# It creates a TUN device for mitmproxy to terminate, points the default route
# at it, installs an iptables kill switch, then drops all privileges and stays
# alive to keep the namespace pinned. Sibling containers (mitmproxy, agent)
# attach via `network_mode: "service:netns"` and inherit the tunnel and
# firewall without holding NET_ADMIN themselves.
#
# ── Why a TUN device rather than a WireGuard tunnel ──────────────────────────
# mitmproxy can terminate either. WireGuard mode was used previously because
# mitmproxy lived in its own network namespace and needed a transport to reach
# into this one; that cost a keypair exchange, a handshake, fwmark policy
# routing to exempt the tunnel's own UDP, and a local dnsmasq to keep the
# engine's embedded DNS from leaking queries around the tunnel.
#
# In TUN mode mitmproxy joins this namespace and holds the TUN device directly,
# so none of that transport machinery exists to secure. The encryption
# WireGuard provided was never protecting anything here — both endpoints were
# already colocated on the same host.
#
# ── Privilege model ─────────────────────────────────────────────────────────
# Creating a TUN device passes two independent gates:
#   1. DAC   — opening /dev/net/tun, which is mode 0600 root:root
#   2. CAP_NET_ADMIN — the TUNSETIFF ioctl that binds a name to the device
#
# This script starts as root with NET_ADMIN so it can pass both. It creates the
# device *persistent* and assigns ownership to the proxy's UID. A persistent
# TUN can then be reopened by its owning UID with no capabilities at all, which
# is why the mitmproxy container runs with `cap_drop: [ALL]` — the component
# parsing untrusted traffic holds zero privilege.
#
# After setup this script drops to an unprivileged UID (needing CAP_SETUID and
# CAP_SETGID to do so) and sleeps. From that point nothing in the namespace can
# alter the routing or firewall it installed.
#
# ── Why egress is filtered by UID ───────────────────────────────────────────
# mitmproxy now shares this namespace with the agent, so it cannot be isolated
# by interface alone: the proxy legitimately needs to reach the internet to
# forward what it has inspected, while the agent must never reach it directly.
# The kill switch therefore distinguishes them by socket owner: only the
# proxy's UID may egress via the physical interface.
#
# That check is only as strong as the UID boundary. A process that can setuid
# to the proxy's UID can bypass it, so the agent must never share the proxy's
# UID — and if the agent is granted container-root (for package installs), it
# must run in its own user namespace so its "root" maps to a distinct,
# unprivileged host UID that cannot reach the proxy's. See compose-all.yml.
#

TUN_DEV="${SANDCAT_TUN_DEV:-tun0}"
TUN_ADDR="${SANDCAT_TUN_ADDR:-10.99.0.1/24}"
TUN_MTU="${SANDCAT_TUN_MTU:-1420}"

# UID/GID mitmproxy runs as. Must match the `user:` of the mitmproxy service
# and must differ from any UID the agent can assume — the kill switch's egress
# exemption is keyed on it.
PROXY_UID="${SANDCAT_PROXY_UID:-1001}"
PROXY_GID="${SANDCAT_PROXY_GID:-1001}"

# Unprivileged UID this script drops to once setup is done. It only has to
# outlive the other containers to keep the namespace alive, so it needs no
# access to anything.
HOLD_UID="${SANDCAT_HOLD_UID:-65534}"
HOLD_GID="${SANDCAT_HOLD_GID:-65534}"

# mitmweb's UI port. Reachable from the host via the published port, but
# blocked on loopback for everyone but the proxy: sharing a namespace means
# the agent would otherwise reach the UI (and its API) at 127.0.0.1.
MITMWEB_PORT="${SANDCAT_MITMWEB_PORT:-8081}"

# Volume shared with mitmproxy. Chowned to the proxy UID here because the
# engine creates named volumes root-owned, and mitmproxy — running with no
# capabilities — cannot fix that itself.
MITMPROXY_CONFIG_DIR="${SANDCAT_MITMPROXY_CONFIG_DIR:-/mitmproxy-config}"

READY_SENTINEL="${SANDCAT_READY_SENTINEL:-/tmp/netns-ready}"

# Nameserver handed to sibling containers. Any address that routes over the
# default route works, because mitmproxy intercepts the DNS conversation off
# the TUN device regardless of who it was addressed to and applies the same
# allow/deny rules it applies to HTTP. It deliberately is *not* the engine's
# embedded resolver: that one is reachable without traversing the TUN device
# and the kill switch blocks it (see killswitch_rules_v4).
#
# The actual upstream resolver is mitmproxy's business, configured through the
# `dns_servers` setting — this address only has to be routable into the tunnel.
AGENT_DNS="${SANDCAT_AGENT_DNS:-1.1.1.1}"

# Siblings share this network namespace but not this mount namespace, so they
# each get their own /etc/resolv.conf from the engine and don't inherit the one
# written here. It's published on a shared volume for their init scripts to
# copy in. See app-init.sh.
SHARED_RESOLV_CONF="${SANDCAT_SHARED_RESOLV_CONF:-/run/sandcat/resolv.conf}"

# Print the IPv4 kill-switch rules, one `iptables` argument list per line.
#
# Split out from application so it can be asserted against in tests without a
# live namespace. Order matters and is significant:
#
#   1. Loopback is allowed, except two things that must precede the general
#      loopback ACCEPT to have any effect: the mitmweb UI, and DNS. The latter
#      matters because container engines expose an embedded resolver inside the
#      namespace — Docker's sits on loopback at 127.0.0.11 — and a resolver
#      reachable without traversing the TUN device is a DNS exfiltration
#      channel that never passes mitmproxy's policy hook. Filtering by port
#      rather than by resolver address closes it the same way on any engine.
#   2. Anything routed into the TUN device is allowed — that is the agent's
#      only sanctioned path out, and mitmproxy is reading the other end.
#   3. The proxy may query the engine's embedded DNS on the gateway, which is
#      how sibling-container names stay resolvable.
#   4. Nothing may address the gateway otherwise — that is the host.
#   5. The proxy may egress to everything else; it is the inspection point.
#   6. Everything else is dropped, backing up the DROP policy explicitly.
#
# Args:
#   $1 - gateway address of the physical interface
#   $2 - name of the physical interface (e.g. eth0)
killswitch_rules_v4() {
	local gateway="$1" iface="$2"

	echo "-A OUTPUT -o lo -p tcp --dport $MITMWEB_PORT -m owner ! --uid-owner $PROXY_UID -j REJECT"
	echo "-A OUTPUT -o lo -p udp --dport 53 -m owner ! --uid-owner $PROXY_UID -j REJECT"
	echo "-A OUTPUT -o lo -p tcp --dport 53 -m owner ! --uid-owner $PROXY_UID -j REJECT"
	echo "-A OUTPUT -o lo -j ACCEPT"
	echo "-A OUTPUT -o $TUN_DEV -j ACCEPT"
	echo "-A OUTPUT -o $iface -m owner --uid-owner $PROXY_UID -d $gateway -p udp --dport 53 -j ACCEPT"
	echo "-A OUTPUT -o $iface -m owner --uid-owner $PROXY_UID -d $gateway -p tcp --dport 53 -j ACCEPT"
	echo "-A OUTPUT -d $gateway -j DROP"
	echo "-A OUTPUT -o $iface -m owner --uid-owner $PROXY_UID -j ACCEPT"
	echo "-A OUTPUT -o $iface -j DROP"
}

# Print the IPv6 kill-switch rules, one `ip6tables` argument list per line.
#
# IPv6 gets a deny-by-default policy even when the network has no IPv6
# connectivity at all. An address arriving later — from a router advertisement
# or an engine config change — would otherwise open an egress path that never
# passes through the TUN device, and would do so silently.
killswitch_rules_v6() {
	echo "-A OUTPUT -o lo -j ACCEPT"
	echo "-A OUTPUT -o $TUN_DEV -j ACCEPT"
	echo "-A OUTPUT -j DROP"
}

# Apply a set of rules produced by the killswitch_rules_* functions.
#
# Args:
#   $1     - the binary to apply with (iptables or ip6tables)
#   stdin  - rules, one argument list per line
apply_rules() {
	local bin="$1"
	local rule
	while IFS= read -r rule
	do
		[[ -n "$rule" ]] || continue
		# Word splitting is intended: each line is an argument list.
		# shellcheck disable=SC2086
		"$bin" $rule
	done
}

# Write a resolv.conf pointing at the tunnel-routed nameserver.
#
# No search domains are carried over. Under the previous design they were what
# let sibling-container names resolve, via a dnsmasq rule forwarding that one
# domain to the engine's embedded resolver — and keeping that carve-out
# required the RFC 5737 sink to stop everything *else* under the domain from
# leaking to the host's resolver. Neither exists here: sibling names resolve
# because mitmproxy looks them up with its own resolv.conf, which still points
# at the engine's resolver, and the lookup passes the policy hook on the way.
#
# Args:
#   $1 - path to write
write_resolv_conf() {
	local out="$1"
	echo "nameserver $AGENT_DNS" > "$out"
}

# Print the name of the physical interface backing the default route.
#
# Not hardcoded to eth0: Podman and Docker agree on eth0 today, but the rules
# built from this are the entire egress boundary, so guessing wrong would
# silently produce a firewall that filters an interface that does not exist.
default_iface() {
	ip -4 route show default | awk '/default/ { print $5; exit }'
}

# Print the gateway address of the default route.
default_gateway() {
	ip -4 route show default | awk '/default/ { print $3; exit }'
}

main() {
	# Production behavior is errexit; kept inside main() so sourcing this file
	# (e.g. from bats tests) doesn't enable errexit in the caller's shell.
	set -e

	local iface gateway
	iface=$(default_iface)
	gateway=$(default_gateway)

	if [[ -z "$iface" || -z "$gateway" ]]
	then
		echo "Failed to determine the default interface/gateway; refusing to configure the kill switch." >&2
		exit 1
	fi

	# ── TUN device ──────────────────────────────────────────────────────────
	# Created persistent and owned by the proxy UID so mitmproxy can attach to
	# it later holding no capabilities. Without `user`/`group` here the device
	# would be root-only and mitmproxy would need NET_ADMIN of its own.
	ip tuntap add dev "$TUN_DEV" mode tun user "$PROXY_UID" group "$PROXY_GID"
	ip address add "$TUN_ADDR" dev "$TUN_DEV"
	ip link set mtu "$TUN_MTU" up dev "$TUN_DEV"

	# ── Routing ─────────────────────────────────────────────────────────────
	# A plain default route, rather than the policy-routing tables the
	# WireGuard setup needed: with no encapsulated tunnel traffic to exempt,
	# there is nothing to steer around the default. The lower metric wins
	# against the engine-provided default without deleting it, so the proxy
	# can still reach the gateway's DNS via the more specific on-link route.
	ip -4 route replace default dev "$TUN_DEV" metric 1

	# ── Kill switch ─────────────────────────────────────────────────────────
	# Installed with a default DROP policy before anything else can use the
	# namespace, so there is no window in which traffic escapes unfiltered.
	iptables -P OUTPUT DROP
	killswitch_rules_v4 "$gateway" "$iface" | apply_rules iptables

	ip6tables -P OUTPUT DROP
	killswitch_rules_v6 | apply_rules ip6tables

	# ── Shared volume ownership ─────────────────────────────────────────────
	# mitmproxy writes its CA cert, wireguard/dns sidecar files and flow state
	# here. Named volumes are created root-owned, and a zero-capability
	# mitmproxy cannot chown them, so it has to happen while we are still root.
	if [[ -d "$MITMPROXY_CONFIG_DIR" ]]
	then
		chown "$PROXY_UID:$PROXY_GID" "$MITMPROXY_CONFIG_DIR"
	fi

	# ── Publish resolv.conf for siblings ────────────────────────────────────
	mkdir -p "$(dirname "$SHARED_RESOLV_CONF")"
	write_resolv_conf "$SHARED_RESOLV_CONF"
	chmod 0644 "$SHARED_RESOLV_CONF"

	touch "$READY_SENTINEL"
	chmod 0644 "$READY_SENTINEL"

	# ── Drop privileges and hold the namespace ──────────────────────────────
	# Everything above is done; from here the process exists only to keep the
	# namespace alive for the containers that joined it. It gives up its UID
	# and every capability first, so a compromise of this container cannot
	# rewrite the firewall it just installed.
	#
	# The namespace must outlive setup: `network_mode: "service:netns"` is
	# resolved when siblings are created, so if this container exited, the
	# siblings would be left pointing at a destroyed namespace.
	exec setpriv \
		--reuid "$HOLD_UID" \
		--regid "$HOLD_GID" \
		--clear-groups \
		--inh-caps=-all \
		--no-new-privs \
		sleep infinity
}

if [[ "${BASH_SOURCE[0]}" = "${0}" ]]
then
	main "$@"
fi
