#!/usr/bin/env bats

setup() {
	load test_helper
	# shellcheck source=../../templates/devcontainer/sandcat/scripts/wg-client-init.sh
	source "$WG_CLIENT_INIT"

	DNS_CONF_FIXTURE="$BATS_TEST_TMPDIR/dns.conf"
	RESOLV_CONF="$BATS_TEST_TMPDIR/resolv.conf"
}

@test "apply_dns_config writes defaults when dns.conf is missing" {
	apply_dns_config "$DNS_CONF_FIXTURE" "$RESOLV_CONF"

	run cat "$RESOLV_CONF"
	assert_success
	assert_line "nameserver 1.1.1.1"
	assert_line "nameserver 8.8.8.8"
}

@test "apply_dns_config uses configured nameservers from dns.conf" {
	printf '10.0.0.10\n10.0.0.11\n' > "$DNS_CONF_FIXTURE"

	apply_dns_config "$DNS_CONF_FIXTURE" "$RESOLV_CONF"

	run cat "$RESOLV_CONF"
	assert_success
	assert_line "nameserver 10.0.0.10"
	assert_line "nameserver 10.0.0.11"
	refute_line "nameserver 1.1.1.1"
	refute_line "nameserver 8.8.8.8"
}

@test "apply_dns_config falls back to defaults when dns.conf is empty" {
	: > "$DNS_CONF_FIXTURE"

	apply_dns_config "$DNS_CONF_FIXTURE" "$RESOLV_CONF"

	run cat "$RESOLV_CONF"
	assert_success
	assert_line "nameserver 1.1.1.1"
	assert_line "nameserver 8.8.8.8"
}

@test "apply_dns_config falls back to defaults when dns.conf has only blank lines" {
	printf '\n\n\n' > "$DNS_CONF_FIXTURE"

	apply_dns_config "$DNS_CONF_FIXTURE" "$RESOLV_CONF"

	run cat "$RESOLV_CONF"
	assert_success
	assert_line "nameserver 1.1.1.1"
	assert_line "nameserver 8.8.8.8"
}

@test "apply_dns_config consumes a final entry without a trailing newline" {
	printf '10.0.0.10' > "$DNS_CONF_FIXTURE"

	apply_dns_config "$DNS_CONF_FIXTURE" "$RESOLV_CONF"

	run cat "$RESOLV_CONF"
	assert_success
	assert_line "nameserver 10.0.0.10"
	refute_line "nameserver 1.1.1.1"
	refute_line "nameserver 8.8.8.8"
}

@test "apply_dns_config replaces (does not append to) an existing resolv.conf" {
	printf 'nameserver 127.0.0.11\n' > "$RESOLV_CONF"
	printf '10.0.0.10\n' > "$DNS_CONF_FIXTURE"

	apply_dns_config "$DNS_CONF_FIXTURE" "$RESOLV_CONF"

	run cat "$RESOLV_CONF"
	assert_success
	assert_line "nameserver 10.0.0.10"
	refute_line "nameserver 127.0.0.11"
}
