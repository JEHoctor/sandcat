#!/usr/bin/env bats

setup() {
	load test_helper
	RESOLV_CONF="$BATS_TEST_TMPDIR/resolv.conf"
}

@test "write_resolv_conf points at the local dnsmasq with preserved search" {
	write_resolv_conf "$RESOLV_CONF" myproj_default

	run cat "$RESOLV_CONF"
	assert_success
	assert_line "nameserver 127.0.0.1"
	assert_line "search myproj_default"
}

@test "write_resolv_conf joins multiple search domains on one line" {
	write_resolv_conf "$RESOLV_CONF" myproj_default cluster.local

	run cat "$RESOLV_CONF"
	assert_success
	assert_line "search myproj_default cluster.local"
}

@test "write_resolv_conf with no search domains omits the search line" {
	write_resolv_conf "$RESOLV_CONF"

	run cat "$RESOLV_CONF"
	assert_success
	assert_line "nameserver 127.0.0.1"
	refute_output --partial "search "
}

@test "write_resolv_conf does not preserve ndots:0 (would defeat split DNS)" {
	# Even if the caller passes search domains, the new resolv.conf must rely
	# on glibc's default ndots:1 so single-label queries are search-expanded
	# and routed to dnsmasq's /<search>/127.0.0.11 rule.
	write_resolv_conf "$RESOLV_CONF" myproj_default

	run cat "$RESOLV_CONF"
	assert_success
	refute_output --partial "ndots"
}

@test "write_resolv_conf replaces (does not append to) an existing file" {
	printf 'nameserver 127.0.0.11\n' > "$RESOLV_CONF"

	write_resolv_conf "$RESOLV_CONF" myproj_default

	run cat "$RESOLV_CONF"
	assert_success
	assert_line "nameserver 127.0.0.1"
	refute_line "nameserver 127.0.0.11"
}
