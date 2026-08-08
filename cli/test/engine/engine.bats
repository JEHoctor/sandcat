#!/usr/bin/env bats

setup() {
	load test_helper

	# shellcheck source=../../lib/engine.bash
	source "$SCT_LIBDIR/engine.bash"

	# Start from a clean slate: the ambient environment may pin an engine.
	unset SANDCAT_ENGINE

	FAKE_BIN="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$FAKE_BIN"
}

# Create a stub engine that echoes back how it was called.
install_fake() {
	local name=$1
	printf '#!/bin/sh\necho "%s $*"\n' "$name" > "$FAKE_BIN/$name"
	chmod +x "$FAKE_BIN/$name"
}

# Point PATH at the stubs installed above, hiding any real engine.
#
# The runner may well have a real podman or docker on PATH — this repo's own
# CI installs one — so detection has to be tested against a PATH where only
# the test's own stubs exist, otherwise "neither engine installed" is
# untestable. PATH can't simply be emptied: bats' own `run` needs mktemp and
# friends. So it's rebuilt as symlinks to everything on the real PATH except
# the two engine binaries, which are left to the stub directory to provide.
use_fake_path() {
	local shim="$BATS_TEST_TMPDIR/shim"
	mkdir -p "$shim"

	# Split PATH with IFS rather than ${PATH//:/...}: the suite runs under
	# BASH_COMPAT=3.2, where pattern substitution does not expand $'\n' the
	# way it does natively, and the loop would silently see nothing.
	local old_ifs=$IFS
	IFS=:
	# Intentional word splitting on the now-colon IFS.
	# shellcheck disable=SC2086
	set -- $PATH
	IFS=$old_ifs

	local dir entry name
	for dir in "$@"; do
		[ -d "$dir" ] || continue
		for entry in "$dir"/*; do
			[ -f "$entry" ] && [ -x "$entry" ] || continue
			name=${entry##*/}
			case "$name" in
				podman | docker) continue ;;
			esac
			[ -e "$shim/$name" ] || ln -s "$entry" "$shim/$name"
		done
	done

	PATH="$FAKE_BIN:$shim"
}

@test "prefers podman when both engines are installed" {
	install_fake podman
	install_fake docker
	use_fake_path
	run sct_engine
	assert_success
	assert_output "podman"
}

@test "falls back to docker when podman is absent" {
	install_fake docker
	use_fake_path
	run sct_engine
	assert_success
	assert_output "docker"
}

@test "SANDCAT_ENGINE overrides autodetection" {
	install_fake podman
	install_fake docker
	use_fake_path
	SANDCAT_ENGINE=docker run sct_engine
	assert_output "docker"
}

@test "sct_engine fails when neither engine is installed" {
	use_fake_path
	run sct_engine
	assert_failure
}

@test "require_engine errors when neither engine is installed" {
	use_fake_path
	run require_engine
	assert_failure
	assert_output --partial "podman or docker required"
}

@test "require_engine errors when the pinned engine is not on PATH" {
	# A typo in SANDCAT_ENGINE should say so, rather than silently falling
	# back to an engine the user did not ask for.
	install_fake docker
	use_fake_path
	SANDCAT_ENGINE=notreal run require_engine
	assert_failure
	assert_output --partial "not on PATH"
}

@test "require_engine succeeds when an engine is available" {
	install_fake podman
	use_fake_path
	run require_engine
	assert_success
}

@test "sct_engine_run invokes the detected engine" {
	install_fake podman
	use_fake_path
	run sct_engine_run volume ls
	assert_success
	assert_output "podman volume ls"
}

@test "sct_engine_compose invokes the engine's compose subcommand" {
	install_fake podman
	use_fake_path
	run sct_engine_compose -f some.yml up -d
	assert_success
	assert_output "podman compose -f some.yml up -d"
}

@test "sct_engine_compose respects the pinned engine" {
	install_fake podman
	install_fake docker
	use_fake_path
	SANDCAT_ENGINE=docker run sct_engine_compose ps
	assert_output "docker compose ps"
}

@test "sct_engine_compose_exec replaces the process with the engine" {
	# `sandcat attach` and `sandcat compose` rely on exec so the terminal and
	# signals go straight to compose. Verified by asserting nothing after the
	# call runs.
	install_fake podman
	use_fake_path
	run bash -c 'source "$1"; sct_engine_compose_exec ps; echo SHOULD_NOT_PRINT' _ "$SCT_LIBDIR/engine.bash"
	assert_success
	assert_output "podman compose ps"
}
