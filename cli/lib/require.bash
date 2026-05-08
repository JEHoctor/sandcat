#!/bin/bash
set -euo pipefail

: "${exitcode_expectation_failed:=168}"

# Ensures a command is available
# Args:
#   $1 - The command name to require
# Returns:
#   0 if command is available or successfully shimmed, non-zero otherwise
require() {
	local -r cmd="$1"

	if ! command -v "$cmd" &>/dev/null
	then
		>&2 echo "$0: $cmd required"
		return "$exitcode_expectation_failed"
	fi

	# Two unrelated tools share the name `yq`: Mike Farah's Go yq (what sandcat
	# uses, with `-o json`, `head_comment`, `env(...)` etc.) and Python yq
	# (kislyuk/yq), which is what `apt install yq` ships on Debian/Ubuntu.
	# Detect the wrong variant up front so users see a clear pointer instead
	# of an opaque parse error mid-init.
	if [[ "$cmd" == "yq" ]] && ! yq --version 2>&1 | grep -q mikefarah
	then
		>&2 echo "$0: sandcat needs Mike Farah's yq (https://github.com/mikefarah/yq); a different 'yq' is on PATH."
		>&2 echo "On Debian/Ubuntu, 'apt install yq' installs the incompatible Python yq (kislyuk/yq)."
		>&2 echo "Install Mike Farah's yq from https://github.com/mikefarah/yq/#install (e.g. 'snap install yq')."
		return "$exitcode_expectation_failed"
	fi
}
