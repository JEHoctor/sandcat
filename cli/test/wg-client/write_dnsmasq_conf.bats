#!/usr/bin/env bats

setup() {
	load test_helper
	DNS_CONF_FIXTURE="$BATS_TEST_TMPDIR/dns.conf"
	DNSMASQ_OUT="$BATS_TEST_TMPDIR/dnsmasq.conf"
}

@test "write_dnsmasq_conf uses defaults and routes the search domain to Docker DNS" {
	write_dnsmasq_conf "$DNS_CONF_FIXTURE" "$DNSMASQ_OUT" myproj_default

	run cat "$DNSMASQ_OUT"
	assert_success
	assert_line "no-resolv"
	assert_line "no-hosts"
	assert_line "listen-address=127.0.0.1"
	assert_line "bind-interfaces"
	assert_line "domain-needed"
	assert_line "bogus-priv"
	assert_line "server=/myproj_default/127.0.0.11"
	assert_line "server=1.1.1.1"
	assert_line "server=8.8.8.8"
}

@test "write_dnsmasq_conf uses custom upstream from dns.conf" {
	printf '10.0.0.10\n10.0.0.11\n' > "$DNS_CONF_FIXTURE"

	write_dnsmasq_conf "$DNS_CONF_FIXTURE" "$DNSMASQ_OUT" myproj_default

	run cat "$DNSMASQ_OUT"
	assert_success
	assert_line "server=10.0.0.10"
	assert_line "server=10.0.0.11"
	refute_line "server=1.1.1.1"
	refute_line "server=8.8.8.8"
}

@test "write_dnsmasq_conf with no search domains emits no Docker DNS routes" {
	write_dnsmasq_conf "$DNS_CONF_FIXTURE" "$DNSMASQ_OUT"

	run cat "$DNSMASQ_OUT"
	assert_success
	refute_output --partial "127.0.0.11"
	assert_line "server=1.1.1.1"
}

@test "write_dnsmasq_conf supports multiple search domains" {
	write_dnsmasq_conf "$DNS_CONF_FIXTURE" "$DNSMASQ_OUT" myproj_default cluster.local

	run cat "$DNSMASQ_OUT"
	assert_success
	assert_line "server=/myproj_default/127.0.0.11"
	assert_line "server=/cluster.local/127.0.0.11"
}

@test "write_dnsmasq_conf falls back to defaults when dns.conf is empty" {
	: > "$DNS_CONF_FIXTURE"

	write_dnsmasq_conf "$DNS_CONF_FIXTURE" "$DNSMASQ_OUT"

	run cat "$DNSMASQ_OUT"
	assert_success
	assert_line "server=1.1.1.1"
	assert_line "server=8.8.8.8"
}

@test "write_dnsmasq_conf truncates an existing config file" {
	printf 'leftover\n' > "$DNSMASQ_OUT"

	write_dnsmasq_conf "$DNS_CONF_FIXTURE" "$DNSMASQ_OUT"

	run cat "$DNSMASQ_OUT"
	assert_success
	refute_line "leftover"
}
