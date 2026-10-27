#!/usr/bin/env bash
set -euo pipefail
case $(uname -s) in MINGW*|MSYS*) jq() { command jq -b "$@"; }; export -f jq; export MSYS_NO_PATHCONV=1 ;; esac
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$project/lib/common.sh"
source "$project/lib/cli.sh"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
record() { jq -cn --args '$ARGS.positional' -- "$@"; }
node_add() { record add "${SB_GENERATE:-0}" "${SB_AUTO_FRONTEND:-1}" "$@"; }
node_change() { record change "$@"; }
node_delete() { record del "$@"; }
node_info() { record info "$@"; }
node_url() { record url "$@"; }
node_qr() { record qr "$@"; }
dns_command() { record dns "$@"; }
host_service() { record service "$@"; }
host_check() { record check "$@"; }
host_update() { record update "$@"; }
host_log() { record log "$@"; }
host_import() { record import "$@"; }
host_install() { record install "$@"; }
host_uninstall() { record uninstall "$@"; }
host_reinstall() { record reinstall "$@"; }
host_fix() { record fix "$@"; }
host_fix_base() { record fix-base; }
host_fix_frontend() { record fix-front; }
host_bbr() { record bbr; }
assert_call() {
    local expected=$1 actual
    shift
    actual=$(manager_main "$@")
    [[ $actual == "$expected" ]] || { printf 'FAIL: command routing: %s\n' "$*" >&2; exit 1; }
}
for alias in change c config; do assert_call '["change","a b","settings","tls.enabled","on"]' "$alias" 'a b' settings tls.enabled on; done
for alias in passwd password pass; do assert_call '["change","a b","passwd","x \" ; $(false)"]' "$alias" 'a b' 'x " ; $(false)'; done
for alias in del d rm; do assert_call '["del","a b"]' "$alias" 'a b'; done
for alias in id uuid; do assert_call '["change","t","id","auto"]' "$alias" t auto; done
for alias in info i; do assert_call '["info","t","settings"]' "$alias" t settings; done
for alias in update u; do assert_call '["update","core","1.14.4"]' "$alias" core 1.14.4; done
for alias in U update.sh; do assert_call '["update","sh","/source path"]' "$alias" '/source path'; done
for alias in import in; do assert_call '["import"]' "$alias"; done
assert_call '["service","restart","caddy"]' r caddy
assert_call '["service","status","sing-box"]' s
assert_call '["add","1","1","reality","auto"]' gen reality auto
assert_call '["add","0","0","vws","front.example"]' no-auto-tls vws front.example
assert_call '["change","t","new","inbound","http"]' new t inbound http
assert_call '["change","t","door-port","443"]' ddp t 443
assert_call '["dns","change","r","server","1.1.1.1"]' dns change r server 1.1.1.1
assert_call '["fix"]' fix-all
for alias in test t; do assert_call '["check"]' "$alias"; done
if manager_main ddel >/dev/null 2>&1; then exit 1; fi
if manager_main restart caddy extra >/dev/null 2>&1; then exit 1; fi
cat >"$work/core" <<'SH'
#!/usr/bin/env bash
jq -cn --args '$ARGS.positional' -- "$@"
SH
chmod +x "$work/core"
SB_CORE=$work/core
assert_call '["rule-set","compile","a b"]' bin rule-set compile 'a b'
assert_call '["schema","-o","a b"]' schema -o 'a b'
assert_call '["generate","reality-keypair"]' pbk
printf 'PASS: command_aliases_and_exact_argument_transport\n'

[[ $(printf '2\n' | choose_index 'test' alpha beta 2>/dev/null) == 1 ]]
[[ $(printf 'bad\n0\n1\n' | choose_index 'test' alpha 2>/dev/null) == 0 ]]
if printf 'q\n' | manager_main >/dev/null 2>&1; then exit 1; fi
if manager_main </dev/null >/dev/null 2>&1; then exit 1; fi
[[ $(printf '\n' | read_text 'test' 'a b' 2>/dev/null) == 'a b' ]]
[[ $(printf 'literal \\ \"\n' | read_text 'test' 2>/dev/null) == 'literal \ "' ]]
printf 'PASS: menus_cancel_on_eof_and_preserve_text\n'
