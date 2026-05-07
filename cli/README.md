# Sandcat CLI

Command-line tool for managing sandcat configurations and Docker Compose setups.

Requires `docker` (and `docker compose`) and [`yq`](https://github.com/mikefarah/yq).

## Modules and Commands

### `sandcat init`

Initializes sandcat for a project. Prompts for any options not provided via flags, then sets up the necessary
configuration files and network settings. Optional volume mounts (agent config, .git, .idea) are included as
commented-out entries in the generated compose file (agent config defaults to active for the selected agent).

Options:
- `--agent` - Agent type: `claude`, `cursor` (skips prompt)
- `--ide` - IDE for devcontainer mode: `vscode`, `jetbrains`, `none` (skips prompt)
- `--stacks` - Comma-separated development stacks to install: `node`, `python`, `java`, `rust`, `go`, `scala`, `ruby`, `dotnet`, `zig` (skips prompt)
- `--proxy` - Proxy UI mode: `web` (default, mitmweb browser UI) or `tui` (mitmproxy console, use with `sandcat proxy` to attach)
- `--features` - Comma-separated optional features: `tui` (proxy console mode), `1password` (1Password secret resolution via `op` CLI)
- `--1password` - Shorthand for `--features 1password`
- `--name` - Project name for Docker Compose (default: derived from directory name)
- `--path` - Project directory (default: current directory)

Selected stacks are installed via [mise](https://mise.jdx.dev/) in the container's Dockerfile. Versions default
to LTS where available (e.g. Node.js LTS, Java LTS). Selecting `scala` automatically includes `java`. Stacks
with a VS Code extension (e.g. `rust-analyzer`, `metals`) have it added to `devcontainer.json`.

Fully non-interactive examples:
```bash
sandcat init --agent claude --ide vscode --stacks "python,node" --name myproject --path /some/dir

# Cursor CLI provider
sandcat init --agent cursor --ide vscode --stacks "python,node" --name myproject --path /some/dir

# With 1Password integration
sandcat init --agent claude --ide vscode --features "1password" --name myproject
```

Note: Cursor agent support currently uses compatibility defaults for auth/network
settings while provider-specific hardening is being expanded.
Use `CURSOR_API_KEY` for Cursor authentication.
Sandcat always bootstraps Cursor CLI with `.network.useHttp1ForAgent = true`.

#### `sandcat init devcontainer`

Sets up a devcontainer configuration for an agent. Copies devcontainer template files and customizes the
compose-all.yml.

Options:
- `--settings-file` - Path to the settings file (relative to project directory)
- `--project-path` - Path to the project directory
- `--agent` - The agent name (e.g., `claude`, `cursor`)
- `--ide` - The IDE name (e.g., `vscode`, `jetbrains`, `none`) (optional)
- `--stacks` - Space-separated development stacks (e.g., `"python java"`) (optional)
- `--name` - Project name for Docker Compose (default: `{dir}-sandbox`)

#### `sandcat init settings`

Creates a network settings file for the proxy.

Arguments:
- First argument: Path to the settings file

### `sandcat destroy`

Removes all sandcat configuration and containers from a project. Stops running containers, removes volumes, and
deletes configuration directories.

### `sandcat version`

Displays the current version of sandcat.

### `sandcat compose`

Runs docker compose commands with the correct compose file automatically detected. Pass any docker compose arguments
(e.g., `sandcat compose up -d` or `sandcat compose logs`).

### `sandcat edit compose`

Opens the Docker Compose file in your editor. If you save changes and containers are running, it will restart containers by default to apply the changes.

Options:
- `--no-restart` — Do not automatically restart containers after changes. When set (or when `SANDCAT_NO_RESTART=true`), a warning is shown instead with instructions to run `sandcat compose up -d` manually.

### `sandcat edit project-settings`

Opens the project network settings file (`.sandcat/settings.json`) in your editor.

### `sandcat edit user-settings`

Opens the user-wide settings file (`~/.config/sandcat/settings.json`) in your editor. This file contains git
identity, API key secrets, and service-specific network rules.

### `sandcat edit dockerfile`

Opens the container Dockerfile (`.devcontainer/Dockerfile.app`) in your editor. Use this to add or change
development stack versions installed via mise.

### `sandcat proxy`

Opens the mitmproxy interface for traffic inspection. Behavior depends on the proxy mode chosen during
`sandcat init`:
- **web** (default): prints the mitmweb URL and password
- **tui**: tails the mitmdump flow log (Ctrl+C to stop)

### `sandcat restart-proxy`

Restarts the mitmproxy and wg-client services to pick up settings changes. Run this after editing any settings
file (project or user) to apply the new configuration.

### `sandcat run`

Runs a command inside the agent container. If no command is specified, opens a shell. Example: `sandcat run` opens a
shell, `sandcat run npm install` runs npm inside the container.

Options:
- `--build` — Rebuild images before running (e.g. after editing `Dockerfile.app`)

## Directory Structure

Each module is contained in its own directory under `cli/libexec/`.
Modules can be decomposed into multiple commands, the default command being the module's name
(e.g.`cli/libexec/init/init`)
The entrypoint extends the `PATH` with the current module's libexec directory, so that it can call other commands in the
same module by their name.

```
cli/
├── bin/
│   └── sandcat           # Main CLI entry point
├── lib/                   # Shared library functions
├── libexec/               # Module implementations
│   ├── destroy/           #    Each module can contain multiple commands
│   ├── init/
│   └── version/
├── support/               # BATS and it's extensions
├── templates/             # Configuration templates
└── test/             	   # BATS tests
```

## Environment Variables

### Internal (set by the CLI)

- `SCT_ROOT` - Root directory of sandcat CLI
- `SCT_LIBDIR` - Library directory (default: `$SCT_ROOT/lib`)
- `SCT_LIBEXECDIR` - Directory for module implementations (default: `$SCT_ROOT/libexec`)
- `SCT_TEMPLATEDIR` - Directory for templates (default: `$SCT_ROOT/templates`)

### Configuration (set before running `sandcat init`)

These override defaults during compose file generation. Optional volumes default to `false` (commented out),
except provider config mounts, which default to `true` for the selected agent.

- `SANDCAT_MOUNT_CLAUDE_CONFIG` - `true` to mount host `~/.claude` config (Claude agent only)
- `SANDCAT_MOUNT_CURSOR_CONFIG` - `true` to mount host `~/.cursor` config (Cursor agent only)
- `SANDCAT_MOUNT_GIT_READONLY` - `true` to mount `.git/` directory as read-only
- `SANDCAT_MOUNT_IDEA_READONLY` - `true` to mount `.idea/` directory as read-only (JetBrains)

## Settings reference

Settings live in three optional layers, merged with the lower layer first and the higher one taking
precedence:

1. User: `~/.config/sandcat/settings.json`
2. Project: `.sandcat/settings.json`
3. Project local: `.sandcat/settings.local.json` (gitignored)

### `dns_servers`

Top-level optional array of IPv4/IPv6 addresses. Overrides the upstream DNS servers used by the
agent's WireGuard client. Use this to point at your corporate/intranet resolver so internal
hostnames (e.g. `*.corp.example.com`) work inside the sandbox. Empty list, omitted, or explicit
`null` falls back to `1.1.1.1` and `8.8.8.8`. Hostnames are not accepted (resolv.conf `nameserver`
directives require numeric IPs); invalid entries are skipped with a warning in the mitmproxy log.

```json
{
  "dns_servers": ["10.20.0.10", "10.20.0.11"]
}
```

Higher-precedence layers replace the entire list ("last wins"); they are not merged. Setting
`"dns_servers": null` in a higher layer explicitly resets back to defaults regardless of what a
lower layer set. After editing, run `sandcat restart-proxy` for the change to take effect.

### Container-to-container DNS

The agent can resolve sibling containers on the same Docker compose network by name (e.g. a
`db:` service in `compose.yml` is reachable as `db`). Internally the wg-client runs a small
`dnsmasq` that splits DNS: queries under the compose project's network (the `search` domain
Docker assigns to the container) go to Docker's embedded resolver at `127.0.0.11`, while
everything else is forwarded through the WireGuard tunnel to mitmproxy and out via the
configured upstream. No configuration is required.

The agent shares wg-client's network namespace via `network_mode` but Docker still gives each
container its own `/etc/resolv.conf` in its own mount namespace. wg-client publishes its
resolv.conf onto a shared `wg-runtime` volume mounted read-only at `/run/sandcat` in the
agent, and `app-init.sh` copies it into `/etc/resolv.conf` on startup so the agent's lookups
also go through the local dnsmasq.

To prevent the search-domain carve-out from becoming a DNS exfiltration channel — where an
attacker-crafted name like `<payload>.<project>_default` would otherwise be forwarded by
Docker's embedded resolver to the host's upstream DNS, bypassing mitmproxy — wg-client is
launched with a `dns:` sink (RFC 5737 `192.0.2.1`). Sibling-container names continue to
resolve locally; everything else under the search domain that isn't a known sibling fails
fast without leaving the host.
