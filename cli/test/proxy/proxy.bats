#!/usr/bin/env bats

setup() {
	load test_helper

	# shellcheck source=../../libexec/proxy/proxy
	source "$SCT_LIBEXECDIR/proxy/proxy"

	mkdir -p "$BATS_TEST_TMPDIR/.devcontainer"
	COMPOSE_FILE="$BATS_TEST_TMPDIR/.devcontainer/compose-all.yml"
	touch "$COMPOSE_FILE"
}

teardown() {
	unstub_all
}

@test "proxy tails logs in console mode" {
	stub docker \
		"compose -f $COMPOSE_FILE config --format json : echo '{\"services\":{\"netns\":{}}}'" \
		"compose -f $COMPOSE_FILE logs -f mitmproxy : :"

	cd "$BATS_TEST_TMPDIR"
	run proxy
	assert_success
	assert_output --partial "Following mitmproxy logs"
}

@test "proxy shows URL in web mode" {
	stub docker \
		"compose -f $COMPOSE_FILE config --format json : echo '{\"services\":{\"netns\":{\"ports\":[\"8081\"]}}}'" \
		"compose -f $COMPOSE_FILE port netns 8081 : echo 0.0.0.0:12345"

	cd "$BATS_TEST_TMPDIR"
	run proxy
	assert_success
	assert_output --partial "http://0.0.0.0:12345"
}

@test "proxy fails when not running in web mode" {
	stub docker \
		"compose -f $COMPOSE_FILE config --format json : echo '{\"services\":{\"netns\":{\"ports\":[\"8081\"]}}}'" \
		"compose -f $COMPOSE_FILE port netns 8081 : exit 1"

	cd "$BATS_TEST_TMPDIR"
	run proxy
	assert_failure
	assert_output --partial "not running"
}
