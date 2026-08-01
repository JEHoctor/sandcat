#!/usr/bin/env bash
# Container engine abstraction.
#
# Sandcat shells out to a container engine for everything (compose, volumes,
# image inspection); it never speaks the engine's HTTP API. That makes the
# engine a swappable dependency, provided call sites go through the helpers
# here instead of hardcoding `docker`.
#
# Podman is preferred when both are installed, because sandcat's network
# isolation relies on capability separation that Podman expresses natively:
# a `--userns` mapped agent gets container-root (for package installs) while
# remaining an unprivileged UID on the host, and that host-level UID
# distinction is what makes the proxy's uid-based egress rules sound. See
# sandcat/scripts/netns-init.sh for the full reasoning.

# shellcheck source=logging.bash
source "$SCT_LIBDIR/logging.bash"

# Print the container engine sandcat should use.
#
# Honors SANDCAT_ENGINE when set (so users on a mixed host, or CI, can pin
# one), otherwise prefers podman and falls back to docker. Prints nothing and
# returns non-zero when neither is installed; callers should route that
# through require_engine() for a readable message.
sct_engine() {
	if [[ -n "${SANDCAT_ENGINE:-}" ]]
	then
		echo "$SANDCAT_ENGINE"
		return 0
	fi

	if command -v podman &>/dev/null
	then
		echo podman
		return 0
	fi

	if command -v docker &>/dev/null
	then
		echo docker
		return 0
	fi

	return 1
}

# Ensure a usable container engine is on PATH, erroring out if not.
#
# Returns:
#   0 when an engine is available, $exitcode_expectation_failed otherwise
require_engine() {
	local engine
	if ! engine=$(sct_engine) || [[ -z "$engine" ]]
	then
		>&2 echo "$0: podman or docker required (set SANDCAT_ENGINE to pin one)"
		return "${exitcode_expectation_failed:-168}"
	fi

	if ! command -v "$engine" &>/dev/null
	then
		>&2 echo "$0: SANDCAT_ENGINE=$engine, but '$engine' is not on PATH"
		return "${exitcode_expectation_failed:-168}"
	fi
}

# Run the configured engine with the given arguments.
# All arguments are passed through verbatim.
sct_engine_run() {
	local engine
	engine=$(sct_engine) || return 1
	"$engine" "$@"
}

# Run the configured engine's compose implementation.
#
# Both `docker compose` and `podman compose` accept the same subcommands and
# file layout, so call sites need no branching. Note that `podman compose`
# delegates to whichever compose provider is installed (podman-compose or the
# Docker Compose binary), which is why sandcat sticks to portable compose
# features rather than provider-specific extensions.
sct_engine_compose() {
	sct_engine_run compose "$@"
}

# Replace the current process with the engine's compose implementation.
#
# For the interactive entry points (`sandcat attach`, `sandcat compose`), which
# previously ran `exec docker compose ...`. Keeping exec matters there: it hands
# the terminal and signal handling straight to compose instead of leaving a
# parent shell in between. It has to resolve the engine to a real command first,
# because exec cannot replace the process with a shell function.
sct_engine_compose_exec() {
	local engine
	engine=$(sct_engine) || return 1
	exec "$engine" compose "$@"
}
