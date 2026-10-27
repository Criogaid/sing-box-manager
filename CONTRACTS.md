# Module contracts

These are newly designed integration boundaries. They specify data and behavior, not algorithms. All functions return nonzero on failure, print Chinese diagnostics to stderr, and never exit the calling shell. Data results use stdout. Root `sb` sources the modules then invokes `manager_main "$@"`.

## Common (lead-owned `lib/common.sh`)

`runtime_init` resolves these environment-overridable paths once:

- `SB_ROOT` default `/etc/sing-box`; `SB_CORE` default `$SB_ROOT/bin/sing-box`; `SB_MAIN=$SB_ROOT/config.json`; `SB_PARTS=$SB_ROOT/conf`; `SB_META=$SB_ROOT/script.json`.
- `SB_CADDY_ROOT` default `/etc/caddy`; `SB_CADDY` default `/usr/local/bin/caddy`; `SB_CADDYFILE=$SB_CADDY_ROOT/Caddyfile`; `SB_SITES=$SB_CADDY_ROOT/sing-box`.
- `SB_PROJECT` is this program's directory (root containing `sb` and `lib`); `SB_WORK` is a per-invocation private temp directory, cleaned by the root command's EXIT trap. Modules don't change that trap.
- `SB_SERVICE_MANAGER` optional `systemd|openrc|none`, auto-detect when omitted. `none` suppresses service operations only for isolated tests/offline work, not validation. `SB_VERSION=0.1.0` comes from root `VERSION` file.

Utilities: `fail MESSAGE` prints to stderr and returns 1; `read_text PROMPT [DEFAULT]` prints prompt to stderr, reads one line, stdout value (EOF nonzero); `choose_index PROMPT CHOICE...` prints numbered options on stderr, reads one-based selection, stdout zero-based integer, `q`/EOF cancels; `new_id` returns a UUID via core; `free_port` returns unused high TCP/UDP port by checking ss; `server_address` reads metadata server or uses public IP discovery (only if needed). `json_temp` creates an empty file under SB_WORK and returns its path.

## Documents and frontends (worker A owns `lib/documents.sh`, `lib/frontend.sh`, `tests/documents.sh`, `tests/frontend.sh`)

- `documents_list`: NUL-separated absolute paths, main then sorted parts (existing only).
- `documents_inventory`: JSON array `{file:string,index:number,value:object}` for every inbound.
- `documents_select SELECTOR`: returns one such object, tag first then exact filename then regex filename; choice menu if multiple. Omitted/empty selector lists selectable inbounds, hide dedicated ShadowTLS inner nodes unless explicitly tagged.
- `documents_merge OUTPUT_FILE`: writes actual core merge of all files to output.
- `documents_check TARGET_FILE CANDIDATE_FILE`: validates replacing/adding this one whole document in complete configuration using core, no active writes.
- `documents_commit TARGET_FILE CANDIDATE_FILE`: calls check and `frontend_reconcile BEFORE_FILE AFTER_FILE check`, atomically writes candidate preserving existing mode, then frontend apply and `host_service restart sing-box`; references and unknown root sections preserved by caller. No rollback framework. Removal represented by full document without selected object; empty inbound-only fragments may be deleted after validation. No restart for semantically identical document.
- `frontend_lookup INBOUND_FILE`: JSON `null` if no match or `{file,host,port,backend,path,transport}` for matched Caddy route. `port` is public integer, backend is integer. Ambiguous mappings error. Detect live route using actual content, not assumed filename.
- `frontend_reconcile BEFORE_FILE AFTER_FILE check|apply`: synchronize already-associated routes by tag with positional fallback for untagged entries; backend/path/protocol removed or changed. Check produces no live changes; apply writes then calls `host_service restart caddy` if needed. Preserve unrelated directives and `.add`. Core candidate and Caddy candidate validate before any commit. Reject incompatible TLS-enabled backend on existing plain route. No schema whitelist.
- `frontend_create INBOUND_FILE HOST PUBLIC_PORT check|apply`: create managed site + global imports if needed, support WS/HTTP/HTTPUpgrade; caller supplies loopback inbound. Real Caddy adapt validation. Apply restarts Caddy. Caller invokes check before documents_commit.
- `frontend_edit INBOUND_FILE FIELD VALUE`: FIELD `port|host|web`, validates+applies matching route, preserves unknown content; restarts Caddy. Returns nonzero if no association. Helpers may be private `_front_*`.

## Schema and field forms (worker B owns `lib/forms.sh`, `lib/schema.jq`, `tests/forms.sh`)

- `forms_init`: run current core schema into SB_WORK, set `SB_SCHEMA` path; lazy per invocation. No static protocol list.
- `forms_types Inbound|DNSServer`: line-delimited type names.
- `forms_definition NAME [TYPE]`: output node JSON. NAME `Inbound|DNSServer|DNS|Config`. `Config` means form containing only inbounds and dns root fields for related edits.
- `forms_edit NODE_JSON DATA_FILE`: interactive recursive editing. Changes DATA_FILE only on successful completion, cancellation preserves original. Show current configured value/presence; omit optional defaults. Private keys redacted. Branch selectors support const and enum discriminators, scalar-to-array union switching; branch-specific non-discriminator fields are retained for explicit edit/removal.
- `forms_set NODE_JSON DATA_FILE FIELD_PATH TEXT_VALUE`: only scalar field assignment using schema; nested dot paths allowed for known object fields. Boolean `on/off/true/false/enable/disable`. Preserve number/bool/string types and reject non-scalar input. No raw JSON interface. Does not commit configuration.
- `forms_show DATA_FILE`: human-readable nested paths and values, includes unknown fields, redacts private_key, handles multiline safely. Accept files, not stdin (caller supplies file).

## Nodes and DNS (worker C owns `lib/nodes.sh`, `lib/links.jq`, `tests/nodes.sh`)

- `node_add [PRESET [ARGS...]]`: empty opens preset/type selection; `inbound [TYPE]` full core-driven form. Collect metadata and use documents_commit. Legacy preset aliases; add creates one file with one or related inbounds and optional DNS. `SB_GENERATE=1` outputs candidate only (no write/service/TLS file creation). `SB_AUTO_FRONTEND=0` no automatic Caddy creation. Read requirements for protocols. Standard option arguments should prompt when absent.
- `node_change SELECTOR [FIELD [VALUE...]]`: no FIELD shows edit menu; `settings [PATH VALUE]` uses forms; `new [PRESET ARGS...]` changes selected protocol; common shortcuts `port,path,passwd,id,key,sni,method,host,web,username,door-addr,door-port,full`. Preserve other document data. For multiple users, shortcut must choose or reject ambiguity with a menu option rather than edit wrong account.
- `node_delete [SELECTOR]`; `node_info [SELECTOR] [settings]`; `node_url [SELECTOR]`: node_url prints URI only; errors if unsupported. `node_qr [SELECTOR]`: local qrencode of URI, no webpage. Public node view derives fields from actual data, Reality public key via OpenSSL, Caddy endpoint from frontend_lookup. URL output never exposes private key.
- `dns_command [OPERATION ARGS...]`: operations add/change/del/info/settings above; shortcuts `set ADDRESS`, `none`, and well-known default resolver selection permitted. Records across documents retain source location. Menu exposes server list and root options; preserve other DNS settings.

## Host lifecycle (worker D owns `lib/host.sh`, `install.sh`, `tests/host.sh`)

- `host_service ACTION [COMPONENT]`: actions start/stop/restart/status/enable/disable; component sing-box default or caddy. Auto manager per common config. Before start/restart validate relevant configuration (core check or caddy adapt). `none` returns success for test/offline service actions.
- `host_log [ARG]`: behavior per requirements.
- `host_update core|caddy|sh [VERSION_OR_DIRECTORY]`: core/Caddy official release; sh install this project from local dir with `install.sh --adopt`; use latest release if no version. Do not corrupt installed binary when download/check fails. No network in tests except explicit core integration.
- `host_install [ARGS]` runs `$SB_PROJECT/install.sh`; `host_reinstall` keeps independent source copy until reinstall finishes, destructive original intent requires user confirmation; `host_uninstall` explicitly confirms and removes only managed paths. No actual destructive test calls.
- `host_import`: convert known Xray/V2Ray script config directories using jq, core validates first, source removed only after successful corresponding commit. Interactive selection allowed; report unsupported protocols instead of silently misconvert.
- `host_fix [SELECTOR]` validates selected config and syncs frontend; `host_fix_base` fills only missing root log/dns/outbounds; `host_fix_frontend` verifies Caddy; `host_bbr` checks kernel capability and sets persistent fq+bbr when supported, explicit interactive action only.
- `install.sh --adopt [SERVER_ADDRESS]`: installs only scripts/README/LICENSE into `$SB_ROOT/manager`, symlinks `sb` and `sing-box` in `SB_BIN_DIR` default `/usr/local/bin`; verify existing config, preserve runtime files/PID. With no --adopt installs new core (official download or `--core-file FILE`, optional `--core-version VER`, `--proxy URL`, `--local-install` for cwd source) and init service. Never downloads another manager. Need original tests with stubs. Source module APIs through root lib load or installer bootstrap; avoid executing root dispatch while sourcing.

## Command adapter (lead owns `sb`, `lib/cli.sh`, `tests/run.sh`, `tests/cli.sh`)

Maps aliases exactly once, coordinates functions above and menu. Native core passthrough for unknown commands, `bin ...` explicit. Test all alias mappings and cancel paths with stubs. No protocol-specific JSON mutation here. `pbk` calls core generate reality-keypair; `ip`, `get-port`, `ss2022`, `gen`, `no-auto-tls`, `test`, `version`, `help`, bulk deletion are coordinated here.

## Test convention

Each test is a standalone Bash script with `set -euo pipefail`, resolves project root from own path, uses mktemp cleanup, sources only required modules + common.sh, creates SB_WORK/SB_ROOT explicitly, and uses stubs for host_service if needed. Windows Git Bash must use jq -b only there to avoid CRLF artifacts. Tests must exercise behavior and whole JSON values, not assert prose messages. Optional real tools through `TEST_CORE`, `TEST_CADDY`, `TEST_SCHEMA` variables. No production paths or network operations by default.

### Shared core check

`host_check [BINARY]` checks all active configuration using the core from `SB_ROOT` as its working directory. Service actions, core updates, adoption, and CLI `test` all use this owner so relative resource paths match the installed service.
