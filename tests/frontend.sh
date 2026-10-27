#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT
case $(uname -s) in MINGW*|MSYS*) TEMP=$(cd "$TEMP" && pwd -W); jq() { command jq -b "$@"; }; export -f jq;; esac
export SB_ROOT="$TEMP/core" SB_CADDY_ROOT="$TEMP/caddy" SB_WORK="$TEMP/work" SB_PROJECT="$PROJECT" SB_SERVICE_MANAGER=none
mkdir -p "$SB_WORK" "$SB_ROOT/conf" "$SB_CADDY_ROOT/sing-box" "$SB_CADDY_ROOT/sites"
source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/documents.sh"
source "$PROJECT/lib/frontend.sh"
runtime_init
host_service() { printf '%s %s\n' "$1" "$2" >> "$TEMP/services"; }
cat > "$TEMP/caddy-stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == adapt && $2 == --adapter && $3 == caddyfile && $4 == --config ]]
root=$(dirname "$5")
validate=0
for arg in "$@"; do [[ $arg != --validate ]] || validate=1; done
if [[ $validate == 1 ]]; then
    [[ -z ${CADDY_VALIDATE_REJECT:-} ]] || exit 1
    [[ -z ${CADDY_RESOURCE_PROBE:-} ]] || cmp "$CADDY_RESOURCE_PROBE" "$CADDY_RESOURCE_EXPECTED"
fi
if [[ -n ${CADDY_REJECT:-} ]]; then exit 1; fi
# 替身只模拟拒绝；真实语法检查由 TEST_CADDY 执行。
[[ -f $5 ]]
printf '{}\n'
STUB
chmod +x "$TEMP/caddy-stub"
SB_CADDY=${TEST_CADDY:-$TEMP/caddy-stub}
printf 'import "%s/sing-box/*.conf"\nimport "%s/sites/*.conf"\n' "$SB_CADDY_ROOT" "$SB_CADDY_ROOT" > "$SB_CADDYFILE"
cat > "$SB_SITES/arbitrary.conf" <<'SITE'
# untouched comment
example.invalid:8443 {
    header X-Keep "a # quoted value"
    handle /socket {
        reverse_proxy localhost:12001 {
            header_up X-Backend "untouched"
        }
    }
    handle {
        reverse_proxy https://www.example.invalid
    }
}
SITE
printf '# custom fragment remains\n' > "$SB_SITES/arbitrary.conf.add"
printf 'other.invalid:8080 {\n    respond "untouched"\n}\n' > "$SB_CADDY_ROOT/sites/extra.conf"
printf '%s\n' '{"inbounds":[{"type":"vmess","tag":"node","listen":"127.0.0.1","listen_port":12001,"transport":{"type":"ws","path":"/socket"}}]}' > "$TEMP/before"
jq '.inbounds[0]' "$TEMP/before" > "$TEMP/before-node"
if frontend_lookup "$TEMP/before" 2>/dev/null; then exit 1; fi
frontend_lookup "$TEMP/before-node" | jq -e '.host=="example.invalid" and .port==8443 and .backend==12001 and .path=="/socket"' >/dev/null
cp "$SB_SITES/arbitrary.conf" "$TEMP/original"
cp "$SB_SITES/arbitrary.conf.add" "$TEMP/add"
cp "$SB_CADDY_ROOT/sites/extra.conf" "$TEMP/extra"
jq '.inbounds[0].listen_port=12002 | .inbounds[0].transport.path="/new"' "$TEMP/before" > "$TEMP/after"
jq '.inbounds[0]' "$TEMP/after" > "$TEMP/after-node"
cp "$TEMP/before" "$SB_MAIN"
cat > "$TEMP/core-stub" <<'CORE'
#!/usr/bin/env bash
set -euo pipefail
if [[ $1 == merge ]]; then output=$2; shift 2; while (($#)); do input=$2; shift 2; done; cp "$input" "$output"
else [[ $1 == check && -s $3 ]]; fi
CORE
chmod +x "$TEMP/core-stub"
SB_CORE=${TEST_CORE:-$TEMP/core-stub}

test_frontend_safety() {
    local caddy=$SB_CADDY
    printf '%s\n' '{"type":"hysteria2","tag":"udp","listen":"127.0.0.1","listen_port":12001}' > "$TEMP/udp-node"
    frontend_lookup "$TEMP/udp-node" | jq -e '.==null' >/dev/null
    jq -n --slurpfile n "$TEMP/udp-node" '{inbounds:$n}' > "$TEMP/udp-document"
    printf '%s\n' '{"inbounds":[]}' > "$TEMP/udp-deleted"
    frontend_reconcile "$TEMP/udp-document" "$TEMP/udp-deleted" apply
    cmp "$SB_SITES/arbitrary.conf" "$TEMP/original"
    [[ ! -e $TEMP/services ]]
    jq --slurpfile n "$TEMP/udp-node" '.inbounds += $n' "$TEMP/before" > "$TEMP/shared-port"
    frontend_reconcile "$TEMP/shared-port" "$TEMP/before" apply
    cmp "$SB_SITES/arbitrary.conf" "$TEMP/original"
    [[ ! -e $TEMP/services ]]
    SB_CADDY="$TEMP/caddy-stub"
    export CADDY_VALIDATE_REJECT=1
    "$SB_CADDY" adapt --adapter caddyfile --config "$SB_CADDYFILE" >/dev/null
    if documents_commit "$SB_MAIN" "$TEMP/after"; then exit 1; fi
    cmp "$SB_MAIN" "$TEMP/before"
    cmp "$SB_SITES/arbitrary.conf" "$TEMP/original"
    cmp "$SB_SITES/arbitrary.conf.add" "$TEMP/add"
    cmp "$SB_CADDY_ROOT/sites/extra.conf" "$TEMP/extra"
    [[ ! -e $TEMP/services ]]
    unset CADDY_VALIDATE_REJECT
    mkdir -p "$SB_CADDY_ROOT/certs"
    printf 'synthetic resource\n' > "$SB_CADDY_ROOT/certs/relative.pem"
    cp "$SB_CADDY_ROOT/certs/relative.pem" "$TEMP/resource-expected"
    export CADDY_RESOURCE_PROBE=certs/relative.pem CADDY_RESOURCE_EXPECTED="$TEMP/resource-expected"
    frontend_reconcile "$TEMP/before" "$TEMP/after" check
    unset CADDY_RESOURCE_PROBE CADDY_RESOURCE_EXPECTED
    SB_CADDY=$caddy
    if [[ -n ${TEST_CADDY:-} ]]; then
        openssl req -x509 -newkey rsa:2048 -nodes -keyout "$SB_CADDY_ROOT/certs/relative.key" -out "$SB_CADDY_ROOT/certs/relative.pem" -days 1 -subj /CN=relative.invalid > "$TEMP/openssl.log" 2>&1 || { cat "$TEMP/openssl.log" >&2; exit 1; }
        printf 'https://relative.invalid:9444 {\n    tls certs/relative.pem certs/relative.key\n    respond "synthetic"\n}\n' > "$SB_CADDY_ROOT/sites/relative.conf"
        frontend_reconcile "$TEMP/before" "$TEMP/after" check
        mv "$SB_CADDY_ROOT/certs/relative.pem" "$TEMP/relative.pem"
        if documents_commit "$SB_MAIN" "$TEMP/after"; then exit 1; fi
        cmp "$SB_MAIN" "$TEMP/before"
        cmp "$SB_SITES/arbitrary.conf" "$TEMP/original"
        [[ ! -e $TEMP/services ]]
        mv "$TEMP/relative.pem" "$SB_CADDY_ROOT/certs/relative.pem"
        rm "$SB_CADDY_ROOT/sites/relative.conf"
    fi
    frontend_reconcile "$TEMP/before" "$TEMP/after" apply
    frontend_lookup "$TEMP/after-node" | jq -e '.backend==12002 and .path=="/new"' >/dev/null
    [[ $(wc -l < "$TEMP/services") == 1 ]]
    frontend_reconcile "$TEMP/after" "$TEMP/before" apply
    rm -f "$TEMP/services"
    cmp "$SB_SITES/arbitrary.conf" "$TEMP/original"
}
(cd "$SB_CADDY_ROOT" && test_frontend_safety)
if [[ ${1:-} == safety ]]; then printf 'frontend safety: passed\n'; exit 0; fi

frontend_reconcile "$TEMP/before" "$TEMP/after" check
cmp "$SB_SITES/arbitrary.conf" "$TEMP/original"
[[ ! -e $TEMP/services ]]
if [[ -n ${TEST_CADDY:-} ]]; then
    printf 'broken.invalid {\n    invalid_synthetic_directive\n}\n' > "$SB_CADDY_ROOT/sites/broken.conf"
else export CADDY_REJECT=1; fi
if documents_commit "$SB_MAIN" "$TEMP/after"; then exit 1; fi
cmp "$SB_MAIN" "$TEMP/before"
cmp "$SB_SITES/arbitrary.conf" "$TEMP/original"
rm -f "$SB_CADDY_ROOT/sites/broken.conf"
unset CADDY_REJECT
documents_commit "$SB_MAIN" "$TEMP/after"
jq -e -s '.[0]==.[1]' "$SB_MAIN" "$TEMP/after" >/dev/null
frontend_lookup "$TEMP/after-node" | jq -e '.backend==12002 and .path=="/new" and .transport=="http"' >/dev/null
sed -e 's@localhost:12001@localhost:12002@' -e 's@/socket@/new@' "$TEMP/original" > "$TEMP/expected"
cmp "$SB_SITES/arbitrary.conf" "$TEMP/expected"
cmp "$SB_SITES/arbitrary.conf.add" "$TEMP/add"
cmp "$SB_CADDY_ROOT/sites/extra.conf" "$TEMP/extra"
[[ $(wc -l < "$TEMP/services") == 2 ]]
frontend_reconcile "$TEMP/after" "$TEMP/after" apply
[[ $(wc -l < "$TEMP/services") == 2 ]]
jq '.inbounds[0].tls.enabled=true' "$TEMP/after" > "$TEMP/tls"
if frontend_reconcile "$TEMP/after" "$TEMP/tls" check; then exit 1; fi
cmp "$SB_SITES/arbitrary.conf" "$TEMP/expected"
frontend_edit "$TEMP/after-node" host changed.invalid
frontend_edit "$TEMP/after-node" port 9443
frontend_edit "$TEMP/after-node" web https://cover.invalid
frontend_lookup "$TEMP/after-node" | jq -e '.host=="changed.invalid" and .port==9443 and .backend==12002' >/dev/null
if frontend_edit "$TEMP/after-node" host $'bad\nvalue'; then exit 1; fi
printf 'duplicate.invalid:8444 {\n    reverse_proxy 127.0.0.1:12002\n}\n' > "$SB_SITES/duplicate.conf"
if frontend_lookup "$TEMP/after-node"; then exit 1; fi
rm "$SB_SITES/duplicate.conf"
if [[ -z ${TEST_CADDY:-} ]]; then
    export CADDY_REJECT=1
    cp "$SB_SITES/arbitrary.conf" "$TEMP/unchanged"
    if frontend_edit "$TEMP/after-node" port 10443; then exit 1; fi
    cmp "$SB_SITES/arbitrary.conf" "$TEMP/unchanged"
    unset CADDY_REJECT
fi
printf '%s\n' '{"inbounds":[]}' > "$TEMP/empty"
frontend_reconcile "$TEMP/after" "$TEMP/empty" check
frontend_reconcile "$TEMP/after" "$TEMP/empty" apply
frontend_lookup "$TEMP/after-node" | jq -e '.==null' >/dev/null
printf '%s\n' '{"type":"vmess","tag":"created","listen":"127.0.0.1","listen_port":13001,"transport":{"type":"http","path":"/h2"}}' > "$TEMP/create"
frontend_create "$TEMP/create" new.invalid 8445 check
[[ ! -e $SB_SITES/managed-new.invalid-8445.conf ]]
frontend_create "$TEMP/create" new.invalid 8445 apply
frontend_lookup "$TEMP/create" | jq -e '.host=="new.invalid" and .port==8445 and .transport=="h2c" and .backend==13001' >/dev/null
cmp "$SB_SITES/arbitrary.conf.add" "$TEMP/add"
cmp "$SB_CADDY_ROOT/sites/extra.conf" "$TEMP/extra"
for type in http ws; do
    printf 'header X-Custom "untouched { token"\n' > "$SB_SITES/direct.conf.add"
    cp "$SB_SITES/direct.conf.add" "$TEMP/direct-add"
    {
        printf 'http://direct.invalid:8555 {\n    reverse_proxy /entry localhost:32101'
        if [[ $type == http ]]; then printf ' {\n        transport http {\n            versions h2c\n        }\n    }'; fi
        printf '\n    import direct.conf.add\n    header X-Stay yes\n}\n'
    } > "$SB_SITES/direct.conf"
    jq -n --arg t "$type" '{inbounds:[{type:"vmess",tag:"direct",listen:"127.0.0.1",listen_port:32101,transport:{type:$t,path:"/entry"}}]}' > "$TEMP/direct-before"
    jq '.inbounds[0]' "$TEMP/direct-before" > "$TEMP/direct-before-node"
    frontend_lookup "$TEMP/direct-before-node" | jq -e --arg t "$type" '.path=="/entry" and .backend==32101 and .port==8555 and .transport==(if $t=="http" then "h2c" else "http" end)' >/dev/null
    jq '.inbounds[0].listen_port=32102 | .inbounds[0].transport.path="/updated"' "$TEMP/direct-before" > "$TEMP/direct-after"
    jq '.inbounds[0]' "$TEMP/direct-after" > "$TEMP/direct-after-node"
    cp "$SB_SITES/direct.conf" "$TEMP/direct-original"
    frontend_reconcile "$TEMP/direct-before" "$TEMP/direct-after" check
    cmp "$SB_SITES/direct.conf" "$TEMP/direct-original"
    frontend_reconcile "$TEMP/direct-before" "$TEMP/direct-after" apply
    frontend_edit "$TEMP/direct-after-node" port 8556
    frontend_lookup "$TEMP/direct-after-node" | jq -e '.backend==32102 and .path=="/updated" and .port==8556' >/dev/null
    sed -e 's@localhost:32101@localhost:32102@' -e 's@/entry@/updated@' -e 's@:8555@:8556@' "$TEMP/direct-original" > "$TEMP/direct-expected"
    cmp "$SB_SITES/direct.conf" "$TEMP/direct-expected"
    jq '.inbounds[0].listen="::1"' "$TEMP/direct-after" > "$TEMP/listen-rejected"
    if frontend_reconcile "$TEMP/direct-after" "$TEMP/listen-rejected" check; then exit 1; fi
    cmp "$SB_SITES/direct.conf" "$TEMP/direct-expected"
    jq '.inbounds[0].listen="0.0.0.0"' "$TEMP/direct-after" > "$TEMP/listen-allowed"
    frontend_reconcile "$TEMP/direct-after" "$TEMP/listen-allowed" check
    jq '.inbounds[0].listen_port=32999 | .inbounds[0].listen="::1"' "$TEMP/direct-after" > "$TEMP/unassociated"
    frontend_reconcile "$TEMP/unassociated" "$TEMP/unassociated" check
    jq '.inbounds[0].transport.type = (if .inbounds[0].transport.type=="http" then "ws" else "http" end)' "$TEMP/direct-after" > "$TEMP/switched"
    jq '.inbounds[0]' "$TEMP/switched" > "$TEMP/switched-node"
    frontend_reconcile "$TEMP/direct-after" "$TEMP/switched" apply
    frontend_lookup "$TEMP/switched-node" | jq -e --arg t "$type" '.host=="direct.invalid" and .port==8556 and .transport==(if $t=="http" then "http" else "h2c" end)' >/dev/null
    frontend_reconcile "$TEMP/switched" "$TEMP/direct-after" apply
    frontend_lookup "$TEMP/direct-after-node" | jq -e --arg t "$type" '.transport==(if $t=="http" then "h2c" else "http" end)' >/dev/null
    if [[ $type == ws ]]; then
        jq '.inbounds[0] |= (.type="trojan" | del(.transport))' "$TEMP/direct-after" > "$TEMP/native"
    else cp "$TEMP/empty" "$TEMP/native"; fi
    frontend_reconcile "$TEMP/direct-after" "$TEMP/native" check
    frontend_reconcile "$TEMP/direct-after" "$TEMP/native" apply
    frontend_lookup "$TEMP/direct-after-node" | jq -e '.==null' >/dev/null
    cmp "$SB_SITES/direct.conf.add" "$TEMP/direct-add"
    printf 'http://direct.invalid:8556 {\n    \n    import direct.conf.add\n    header X-Stay yes\n}\n' > "$TEMP/direct-deleted"
    cmp "$SB_SITES/direct.conf" "$TEMP/direct-deleted"
done
[[ -z ${TEST_CADDY:-} ]] || "$SB_CADDY" version
printf 'frontend: passed\n'
