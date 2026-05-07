#!/usr/bin/env bats
#
# Verifies the contract that the mitmproxy addon and wg-client agree on the
# `dns.conf` filename, and that compose-proxy.yml mounts the shared volume at
# both the addon's write target and wg-client's read target.
#

setup() {
	load test_helper
	ADDON="$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/mitmproxy_addon_common.py"
	WG_INIT="$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/wg-client-init.sh"
	COMPOSE="$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-proxy.yml"
}

@test "addon and wg-client agree on the dns.conf basename" {
	local addon_path
	addon_path=$(grep -E '^SANDCAT_DNS_CONF_PATH = ' "$ADDON" | sed -E 's/.*"([^"]+)".*/\1/')
	local wg_path
	wg_path=$(grep -E '^DNS_CONF=' "$WG_INIT" | sed -E 's/.*"([^"]+)".*/\1/')

	[ -n "$addon_path" ]
	[ -n "$wg_path" ]
	assert_equal "$(basename "$addon_path")" "$(basename "$wg_path")"
}

@test "compose-proxy.yml mounts mitmproxy-config at the addon's write directory" {
	local addon_path addon_dir
	addon_path=$(grep -E '^SANDCAT_DNS_CONF_PATH = ' "$ADDON" | sed -E 's/.*"([^"]+)".*/\1/')
	addon_dir=$(dirname "$addon_path")

	addon_dir="$addon_dir" yq -e "
		.services.mitmproxy.volumes[] |
		select(. == \"mitmproxy-config:\" + env(addon_dir))
	" "$COMPOSE"
}

@test "compose-proxy.yml mounts mitmproxy-config at wg-client's read directory" {
	local wg_path wg_dir
	wg_path=$(grep -E '^DNS_CONF=' "$WG_INIT" | sed -E 's/.*"([^"]+)".*/\1/')
	wg_dir=$(dirname "$wg_path")

	wg_dir="$wg_dir" yq -e "
		.services.\"wg-client\".volumes[] |
		select(. == \"mitmproxy-config:\" + env(wg_dir) + \":ro\")
	" "$COMPOSE"
}
