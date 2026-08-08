#!/usr/bin/env bats
#
# The mitmproxy entrypoint is the last privileged step in the stack: it hands
# the TUN device node over and then drops to the proxy UID. If it silently
# failed to drop, mitmproxy — which parses untrusted traffic — would keep root.
# These tests cover the guard rails; the drop itself needs a live device node
# and is exercised end-to-end rather than here.

setup() {
	load test_helper
	INIT="$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/mitmproxy-init.sh"
}

@test "entrypoint script is executable" {
	# It is bind-mounted into the mitmproxy image rather than built into it, so
	# the mode has to survive in git — otherwise the container dies with an
	# opaque "OCI permission denied" before any of it runs.
	[ -x "$INIT" ]
}

@test "refuses to start when the tun device node is missing" {
	# Without this the failure surfaces much later, as mitmproxy's own opaque
	# "Failed to create TUN device / Permission denied".
	SANDCAT_TUN_NODE="$BATS_TEST_TMPDIR/definitely-not-here" \
		run "$INIT" true
	assert_failure
	assert_output --partial "is missing"
	assert_output --partial "devices:"
}

@test "refuses to start if the device node could not be handed over" {
	# chown silently doing nothing (no CAP_CHOWN, or a bind-mounted host node
	# under rootless podman) must not be mistaken for success.
	local fake_node="$BATS_TEST_TMPDIR/tun"
	touch "$fake_node"

	# A chown that reports success without changing the owner.
	local shim="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$shim"
	printf '#!/bin/sh\nexit 0\n' > "$shim/chown"
	chmod +x "$shim/chown"

	PATH="$shim:$PATH" SANDCAT_TUN_NODE="$fake_node" SANDCAT_PROXY_UID=4242 \
		run "$INIT" true
	assert_failure
	assert_output --partial "refusing to start"
}

@test "passes the command through to setpriv with the proxy UID" {
	local fake_node="$BATS_TEST_TMPDIR/tun"
	touch "$fake_node"

	local shim="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$shim"
	printf '#!/bin/sh\nexit 0\n' > "$shim/chown"
	# Report the UID the script is checking for, so it gets past the guard.
	printf '#!/bin/sh\necho 4242\n' > "$shim/stat"
	# Record how setpriv was invoked instead of actually dropping privileges.
	printf '#!/bin/sh\necho "setpriv $*"\n' > "$shim/setpriv"
	chmod +x "$shim/chown" "$shim/stat" "$shim/setpriv"

	PATH="$shim:$PATH" SANDCAT_TUN_NODE="$fake_node" SANDCAT_PROXY_UID=4242 \
		SANDCAT_PROXY_GID=4242 run "$INIT" mitmweb --mode tun:tun0
	assert_success
	assert_output --partial "--reuid 4242"
	assert_output --partial "--regid 4242"
	# No path back to privilege once dropped.
	assert_output --partial "--inh-caps=-all"
	assert_output --partial "--no-new-privs"
	# The actual proxy command survives the wrapper.
	assert_output --partial "mitmweb --mode tun:tun0"
}

@test "clears the stale dns.conf sentinel after dropping privileges" {
	# The removal is an argument to the dropped shell, not something root does:
	# cap_drop takes DAC_OVERRIDE with it, so root cannot write a directory
	# owned by the proxy UID. Assert it is still wired to the right path.
	local fake_node="$BATS_TEST_TMPDIR/tun"
	touch "$fake_node"

	local shim="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$shim"
	printf '#!/bin/sh\nexit 0\n' > "$shim/chown"
	printf '#!/bin/sh\necho 4242\n' > "$shim/stat"
	printf '#!/bin/sh\necho "setpriv $*"\n' > "$shim/setpriv"
	chmod +x "$shim/chown" "$shim/stat" "$shim/setpriv"

	PATH="$shim:$PATH" SANDCAT_TUN_NODE="$fake_node" SANDCAT_PROXY_UID=4242 \
		SANDCAT_MITMPROXY_HOME=/home/mitmproxy/.mitmproxy run "$INIT" mitmweb
	assert_success
	assert_output --partial "/home/mitmproxy/.mitmproxy/dns.conf"
}
