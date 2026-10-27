#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT
case $(uname -s) in MINGW*|MSYS*) TEMP=$(cd "$TEMP" && pwd -W); jq() { command jq -b "$@"; }; export -f jq;; esac
export SB_ROOT="$TEMP/core" SB_CADDY_ROOT="$TEMP/caddy" SB_WORK="$TEMP/work" SB_PROJECT="$PROJECT" SB_SERVICE_MANAGER=none
mkdir -p "$SB_WORK" "$SB_ROOT/conf"
source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/documents.sh"
source "$PROJECT/lib/frontend.sh"
runtime_init
host_service() { printf '%s %s\n' "$1" "$2" >> "$TEMP/services"; }
frontend_reconcile() { [[ ${FRONT_REJECT:-0} == 0 ]]; }
cat > "$TEMP/core-stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case $(uname -s) in MINGW*|MSYS*) jq() { command jq -b "$@"; };; esac
[[ $PWD == "$(cd "$SB_ROOT" && pwd)" ]]
op=$1; shift
if [[ $op == merge ]]; then output=$1; shift; else [[ $op == check ]]; output=$(mktemp "$SB_WORK/check.XXXXXX"); fi
files=()
while (($#)); do [[ $1 == -c ]]; files+=("$2"); shift 2; done
jq -s 'def merge(a;b): reduce (b|keys_unsorted[]) as $k (a; .[$k] = (if (a[$k]|type)=="array" and (b[$k]|type)=="array" then a[$k]+b[$k] elif (a[$k]|type)=="object" and (b[$k]|type)=="object" then merge(a[$k];b[$k]) else b[$k] end)); reduce .[] as $v ({};merge(.;$v))' "${files[@]}" > "$output"
if [[ $op == check ]]; then
    jq -e '(.outbounds // [] | map(.tag)) as $tags | (.route.final // "") as $final | ($final=="" or ($tags|index($final))!=null) and ([.inbounds[]?.tag]|length == (unique|length))' "$output" >/dev/null
fi
STUB
chmod +x "$TEMP/core-stub"
SB_CORE="$TEMP/core-stub"
printf '%s\n' '{"route":{"final":"exit","rules":[{"domain":["example.invalid"],"outbound":"exit"}]},"custom":{"keep":true},"inbounds":[]}' > "$SB_MAIN"
printf '%s\n' '{"outbounds":[{"type":"direct","tag":"exit"}],"inbounds":[{"type":"socks","tag":"a","listen_port":1080}]}' > "$SB_PARTS/a.json"
printf '%s\n' '{"dns":{"rules":[{"domain":["test.invalid"],"action":"reject"}]},"inbounds":[{"type":"direct","tag":"inner"},{"type":"shadowtls","tag":"outer","detour":"inner"}]}' > "$SB_PARTS/b.json"
mapfile -d '' -t files < <(documents_list)
[[ ${#files[@]} == 3 && ${files[0]} == "$SB_MAIN" && ${files[2]} == "$SB_PARTS/b.json" ]]
documents_inventory | jq -e 'length==3 and .[0].file!=.[1].file and .[2].value.detour=="inner"' >/dev/null
documents_select a | jq -e '.index==0 and .value.tag=="a"' >/dev/null
documents_select inner | jq -e '.value.type=="direct"' >/dev/null
documents_select 'a\.json$' | jq -e '.value.tag=="a"' >/dev/null
documents_select '' <<< 2 | jq -e '.value.tag=="outer"' >/dev/null
if documents_select '[' 2>/dev/null; then exit 1; fi
if documents_select '' </dev/null 2>/dev/null; then exit 1; fi
cp "$SB_PARTS/a.json" "$TEMP/before"
printf '%s\n' '{"inbounds":[]}' > "$TEMP/candidate"
if documents_check "$SB_PARTS/a.json" "$TEMP/candidate" 2>/dev/null; then exit 1; fi
cmp "$SB_PARTS/a.json" "$TEMP/before"
jq '.inbounds[0].listen_port=1081' "$SB_PARTS/a.json" > "$TEMP/candidate"
documents_check "$SB_PARTS/a.json" "$TEMP/candidate"
FRONT_REJECT=1
if documents_commit "$SB_PARTS/a.json" "$TEMP/candidate"; then exit 1; fi
cmp "$SB_PARTS/a.json" "$TEMP/before"
FRONT_REJECT=0
chmod 640 "$SB_PARTS/a.json"
mode=$(stat -c %a "$SB_PARTS/a.json")
documents_commit "$SB_PARTS/a.json" "$TEMP/candidate"
[[ $(stat -c %a "$SB_PARTS/a.json") == "$mode" ]]
jq -e '.outbounds[0].tag=="exit" and .inbounds[0].listen_port==1081' "$SB_PARTS/a.json" >/dev/null
[[ $(wc -l < "$TEMP/services") == 1 ]]
documents_commit "$SB_PARTS/a.json" "$TEMP/candidate"
[[ $(wc -l < "$TEMP/services") == 1 ]]
documents_merge "$TEMP/merged"
jq -e '.custom.keep and .route.rules[0].outbound=="exit" and .dns.rules[0].action=="reject" and (.inbounds|length)==3' "$TEMP/merged" >/dev/null
printf '%s\n' '{"inbounds":[{"type":"socks","tag":"extra","listen_port":1090}]}' > "$TEMP/candidate"
documents_commit "$SB_PARTS/new.json" "$TEMP/candidate"
printf '%s\n' '{"inbounds":[]}' > "$TEMP/candidate"
documents_commit "$SB_PARTS/new.json" "$TEMP/candidate"
[[ ! -e $SB_PARTS/new.json ]]

test_detour_references() {
    local target="$SB_PARTS/detour-target.json" source="$SB_PARTS/detour-source.json" draft="$SB_PARTS/detour-draft.json"
    printf '%s\n' '{"inbounds":[{"type":"socks","tag":"detour-target","listen":"127.0.0.1","listen_port":19001}]}' > "$target"
    printf '%s\n' '{"inbounds":[{"type":"socks","tag":"detour-source","listen":"127.0.0.1","listen_port":19002,"detour":"detour-target"}]}' > "$source"
    documents_check "$source" "$source"
    cp "$target" "$TEMP/detour-target-before"
    cp "$source" "$TEMP/detour-source-before"
    cp "$TEMP/services" "$TEMP/detour-services-before"
    printf '%s\n' '{"inbounds":[]}' > "$TEMP/detour-candidate"
    if documents_commit "$target" "$TEMP/detour-candidate"; then exit 1; fi
    cmp "$target" "$TEMP/detour-target-before"
    cmp "$source" "$TEMP/detour-source-before"
    cmp "$TEMP/services" "$TEMP/detour-services-before"
    jq '.inbounds[0].detour="detour-typo"' "$source" > "$TEMP/detour-candidate"
    if documents_commit "$source" "$TEMP/detour-candidate"; then exit 1; fi
    cmp "$target" "$TEMP/detour-target-before"
    cmp "$source" "$TEMP/detour-source-before"
    cmp "$TEMP/services" "$TEMP/detour-services-before"
    printf '%s\n' '{"inbounds":[{"type":"socks","tag":"draft-source","listen":"127.0.0.1","listen_port":19003,"detour":"draft-target"},{"type":"socks","tag":"draft-target","listen":"127.0.0.1","listen_port":19004,"detour":""}]}' > "$TEMP/detour-candidate"
    jq '.inbounds[0].detour="draft-typo"' "$TEMP/detour-candidate" > "$TEMP/detour-invalid"
    if documents_commit "$draft" "$TEMP/detour-invalid"; then exit 1; fi
    [[ ! -e $draft ]]
    cmp "$TEMP/services" "$TEMP/detour-services-before"
    documents_check "$draft" "$TEMP/detour-candidate"
    documents_commit "$draft" "$TEMP/detour-candidate"
    jq -e -s '.[0]==.[1]' "$draft" "$TEMP/detour-candidate" >/dev/null
    [[ $(wc -l < "$TEMP/services") == $(($(wc -l < "$TEMP/detour-services-before")+1)) ]]
    rm -f "$target" "$source" "$draft"
}
test_detour_references
if [[ -n ${TEST_CORE:-} ]]; then
    SB_CORE=$TEST_CORE
    rm -f "$SB_PARTS/"*.json
    printf '%s\n' '{"route":{"final":"exit"},"inbounds":[]}' > "$SB_MAIN"
    printf '%s\n' '{"outbounds":[{"type":"direct","tag":"exit"}]}' > "$SB_PARTS/exit.json"
    printf '%s\n' '{"inbounds":[{"type":"socks","tag":"real","listen":"127.0.0.1","listen_port":1080}]}' > "$TEMP/candidate"
    documents_check "$SB_PARTS/real.json" "$TEMP/candidate"
    printf '%s\n' '{"inbounds":[{"type":"invalid-synthetic-protocol"}]}' > "$TEMP/invalid"
    if documents_check "$SB_PARTS/real.json" "$TEMP/invalid" 2>/dev/null; then exit 1; fi
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$SB_ROOT/key.pem" -out "$SB_ROOT/cert.pem" -days 1 -subj /CN=synthetic.invalid > "$TEMP/openssl.log" 2>&1 || { cat "$TEMP/openssl.log" >&2; exit 1; }
    printf '%s\n' '{"inbounds":[{"type":"trojan","listen":"127.0.0.1","listen_port":18443,"users":[{"password":"synthetic"}],"tls":{"enabled":true,"certificate_path":"cert.pem","key_path":"key.pem"}}]}' > "$TEMP/tls"
    documents_check "$SB_PARTS/tls.json" "$TEMP/tls"
    test_detour_references
    "$SB_CORE" version
fi
printf 'documents: passed\n'
