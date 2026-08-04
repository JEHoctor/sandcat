#!/usr/bin/env bats
#
# The kill switch is the entire egress boundary: if a rule is missing or
# ordered wrong, traffic leaves without passing mitmproxy and nothing else
# catches it. These tests assert the generated rules directly, so a regression
# shows up here rather than only in a live namespace.

setup() {
	load test_helper

	# shellcheck source=../../templates/devcontainer/sandcat/scripts/netns-init.sh
	source "$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/netns-init.sh"
}

# Print the 1-based index of the first rule matching a pattern, or nothing.
rule_index() {
	local pattern=$1
	echo "$RULES" | grep -n -- "$pattern" | head -1 | cut -d: -f1
}

setup_rules_v4() {
	RULES=$(killswitch_rules_v4 "172.17.0.1" "eth0")
}

@test "v4 allows traffic into the TUN device" {
	setup_rules_v4
	echo "$RULES" | grep -q -- "-A OUTPUT -o tun0 -j ACCEPT"
}

@test "v4 drops everything else on the physical interface" {
	setup_rules_v4
	echo "$RULES" | grep -q -- "-A OUTPUT -o eth0 -j DROP"
}

@test "v4 drops traffic addressed to the gateway" {
	# The gateway is the host. Nothing in the namespace may address it,
	# including the proxy — its only exemption is DNS, asserted below.
	setup_rules_v4
	echo "$RULES" | grep -q -- "-A OUTPUT -d 172.17.0.1 -j DROP"
}

@test "v4 lets only the proxy UID egress via the physical interface" {
	setup_rules_v4
	echo "$RULES" | grep -q -- "-A OUTPUT -o eth0 -m owner --uid-owner 1001 -j ACCEPT"
}

@test "v4 lets the proxy reach the engine's embedded resolver on the gateway" {
	# This is what keeps sibling-container names resolvable: mitmproxy looks
	# them up with its own resolv.conf, which still points at the engine.
	setup_rules_v4
	echo "$RULES" | grep -q -- "-m owner --uid-owner 1001 -d 172.17.0.1 -p udp --dport 53 -j ACCEPT"
	echo "$RULES" | grep -q -- "-m owner --uid-owner 1001 -d 172.17.0.1 -p tcp --dport 53 -j ACCEPT"
}

@test "v4 blocks non-proxy DNS on loopback before allowing loopback" {
	# Container engines expose an embedded resolver inside the namespace
	# (Docker's is on loopback at 127.0.0.11). Reaching it does not traverse
	# the TUN device, so it would be a DNS exfiltration channel that never
	# passes the policy hook. The REJECT only works if it precedes the
	# blanket loopback ACCEPT.
	setup_rules_v4
	local dns_udp dns_tcp lo_accept
	dns_udp=$(rule_index "-o lo -p udp --dport 53 -m owner ! --uid-owner 1001 -j REJECT")
	dns_tcp=$(rule_index "-o lo -p tcp --dport 53 -m owner ! --uid-owner 1001 -j REJECT")
	lo_accept=$(rule_index "-A OUTPUT -o lo -j ACCEPT")

	[ -n "$dns_udp" ]
	[ -n "$dns_tcp" ]
	[ -n "$lo_accept" ]
	[ "$dns_udp" -lt "$lo_accept" ]
	[ "$dns_tcp" -lt "$lo_accept" ]
}

@test "v4 blocks the mitmweb UI on loopback before allowing loopback" {
	# mitmproxy shares the namespace, so the agent would otherwise reach the
	# web UI (and its API) at 127.0.0.1. The port stays a host-side affordance.
	setup_rules_v4
	local ui lo_accept
	ui=$(rule_index "-o lo -p tcp --dport 8081 -m owner ! --uid-owner 1001 -j REJECT")
	lo_accept=$(rule_index "-A OUTPUT -o lo -j ACCEPT")

	[ -n "$ui" ]
	[ "$ui" -lt "$lo_accept" ]
}

@test "v4 honours a custom proxy UID" {
	PROXY_UID=4242
	RULES=$(killswitch_rules_v4 "10.0.0.1" "eth0")
	echo "$RULES" | grep -q -- "-A OUTPUT -o eth0 -m owner --uid-owner 4242 -j ACCEPT"
}

@test "v6 denies by default even with no IPv6 connectivity" {
	# An address arriving later (router advertisement, engine config change)
	# would otherwise open an egress path that never passes the TUN device.
	RULES=$(killswitch_rules_v6)
	echo "$RULES" | grep -q -- "-A OUTPUT -j DROP"
	echo "$RULES" | grep -q -- "-A OUTPUT -o tun0 -j ACCEPT"
}

@test "v6 drop is the last rule" {
	RULES=$(killswitch_rules_v6)
	local last
	last=$(echo "$RULES" | tail -1)
	[ "$last" = "-A OUTPUT -j DROP" ]
}

@test "write_resolv_conf points at the tunnel-routed nameserver" {
	# Not the engine's embedded resolver: that one is reachable without
	# traversing the TUN device and the kill switch blocks it.
	local out="$BATS_TEST_TMPDIR/resolv.conf"
	write_resolv_conf "$out"
	run cat "$out"
	assert_output "nameserver 1.1.1.1"
}

@test "write_resolv_conf carries no search domains" {
	# Search domains were what made the previous design need a DNS sink: they
	# let an attacker-crafted name be forwarded to the host's resolver around
	# the tunnel. Sibling names now resolve at mitmproxy instead.
	local out="$BATS_TEST_TMPDIR/resolv.conf"
	write_resolv_conf "$out"
	run grep -c "search" "$out"
	assert_failure
}
