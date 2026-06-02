#!/usr/bin/env bats

setup() {
	load test_helper
	RESOLV_FIXTURE="$BATS_TEST_TMPDIR/resolv.conf"
}

@test "extract_search_domains pulls every label from a search line" {
	cat > "$RESOLV_FIXTURE" <<-EOF
		nameserver 127.0.0.11
		search myproj_default cluster.local
		options ndots:0
	EOF

	run extract_search_domains "$RESOLV_FIXTURE"
	assert_success
	assert_line "myproj_default"
	assert_line "cluster.local"
}

@test "extract_search_domains returns empty when no search line is present" {
	printf 'nameserver 1.1.1.1\n' > "$RESOLV_FIXTURE"

	run extract_search_domains "$RESOLV_FIXTURE"
	assert_success
	assert_output ""
}

@test "extract_search_domains is silent when the file does not exist" {
	run extract_search_domains "$BATS_TEST_TMPDIR/missing"
	assert_success
	assert_output ""
}
