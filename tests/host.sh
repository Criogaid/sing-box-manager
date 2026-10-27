#!/usr/bin/env bash
set -euo pipefail
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
if [[ $(uname -s) == MINGW* ]]; then jq() { command jq -b "$@"; }; export -f jq; fi
if [[ -f $PROJECT/lib/common.sh ]]; then source "$PROJECT/lib/common.sh"; fi
source "$PROJECT/lib/host.sh"
# 不调用包管理器；缺少的平台工具由测试替身提供。
qrencode() { :; }
ss() { :; }
export -f qrencode ss
export SB_WORK="$TMP/work" SB_ROOT="$TMP/runtime" SB_BIN_DIR="$TMP/bin"
export SB_MAIN="$SB_ROOT/config.json" SB_PARTS="$SB_ROOT/conf" SB_META="$SB_ROOT/script.json"
export SB_CORE="$SB_ROOT/bin/sing-box" SB_CADDY="$TMP/caddy" SB_CADDYFILE="$TMP/Caddyfile"
export SB_CADDY_ROOT="$TMP/caddy-root" SB_SITES="$TMP/caddy-root/sing-box"
export SB_SERVICE_MANAGER=none SB_PROJECT="$PROJECT"
export CALLS="$TMP/calls"
mkdir -p "$SB_WORK" "$SB_PARTS" "$SB_ROOT/bin" "$SB_BIN_DIR"
fail() { printf '%s\n' "$*" >&2; return 1; }
json_temp() { mktemp "$SB_WORK/json.XXXXXX"; }
read_text() { local value; IFS= read -r value || return; printf '%s\n' "$value"; }
cat >"$SB_CORE" <<'STUB'
#!/usr/bin/env bash
printf 'core %s\n' "$*" >>"$CALLS"
if [[ ${REQUIRE_ROOT_CHECK:-0} == 1 && ${1:-} == check ]]; then
    [[ -f relative-check-marker ]] || exit 29
fi
[[ ${CORE_FAIL:-0} == 0 ]]
STUB
cp "$SB_CORE" "$SB_CADDY"
chmod 755 "$SB_CORE" "$SB_CADDY"
printf '%s\n' '{"log":{"level":"info"},"inbounds":[],"outbounds":[]}' >"$SB_MAIN"
printf '%s\n' '{"server":"original.example"}' >"$SB_META"
printf '%s\n' '{"inbounds":[]}' >"$SB_PARTS/keep.json"
printf '%s\n' 'example.test { respond "ok" }' >"$SB_CADDYFILE"

documents_merge() { cp "$SB_MAIN" "$1"; }
documents_check() { [[ ${CHECK_FAIL:-0} == 0 ]]; }
documents_commit() {
    documents_check "$1" "$2" || return
    mkdir -p "$(dirname "$1")"
    cp "$2" "$1"
}
frontend_reconcile() { printf 'front %s\n' "$*" >>"$CALLS"; }

# test_service_validation_and_read_only
: >"$CALLS"
host_service status
[[ ! -s $CALLS ]]
host_service restart
[[ -s $CALLS ]]
if CORE_FAIL=1 host_service restart; then exit 1; fi
systemctl() { printf 'systemctl %s\n' "$*" >>"$CALLS"; }
rc-service() { printf 'rc-service %s\n' "$*" >>"$CALLS"; }
rc-update() { printf 'rc-update %s\n' "$*" >>"$CALLS"; }
SB_SERVICE_MANAGER=systemd host_service status caddy
SB_SERVICE_MANAGER=openrc host_service enable
SB_SERVICE_MANAGER=openrc host_service restart caddy
if host_service restart unknown; then exit 1; fi
# 检查使用服务工作目录，调用者所在目录不影响相对路径。
printf 'fixture\n' >"$SB_ROOT/relative-check-marker"
(cd "$TMP"; REQUIRE_ROOT_CHECK=1 host_service restart)
rm "$SB_ROOT/relative-check-marker"

# test_log_level_preserves_output_and_clear_preserves_config
printf 'one\ntwo\n' >"$SB_ROOT/runtime.log"
jq --arg path 'runtime.log' '.log.output=$path | .unknown={kept:true}' "$SB_MAIN" >"$TMP/log.json"
cp "$TMP/log.json" "$SB_MAIN"
host_log debug
jq -e --arg path 'runtime.log' '.log=={level:"debug",output:$path} and .unknown=={kept:true}' "$SB_MAIN" >/dev/null
host_log --no-follow >"$TMP/log-view"
cmp "$SB_ROOT/runtime.log" "$TMP/log-view"
cp "$SB_MAIN" "$TMP/before-clear"
host_log del
[[ ! -s $SB_ROOT/runtime.log ]]
cmp "$SB_MAIN" "$TMP/before-clear"

# test_fix_base_only_fills_absent_keys
printf '%s\n' '{"dns":{"rules":[{"action":"reject"}]},"custom":{"x":1}}' >"$SB_MAIN"
host_fix_base
jq -e '.dns=={rules:[{action:"reject"}]} and .custom=={x:1} and .log=={level:"info"} and .outbounds==[{type:"direct",tag:"direct"}]' "$SB_MAIN" >/dev/null

# test_import_preserves_failed_sources_and_rejects_unknown_fields
export SB_IMPORT_DIR="$TMP/xray"
mkdir -p "$SB_IMPORT_DIR"
cat >"$SB_IMPORT_DIR/valid.json" <<'JSON'
{"inbounds":[{"tag":"original","protocol":"vless","port":"12345","settings":{"decryption":"none","clients":[{"id":"00000000-0000-4000-8000-000000000001","email":"sample"}]},"streamSettings":{"network":"ws","wsSettings":{"path":"/sample","headers":{"Host":"sample.test"}}}}]}
JSON
cat >"$SB_IMPORT_DIR/unsupported.json" <<'JSON'
{"inbounds":[{"protocol":"vmess","port":12346,"settings":{"clients":[]},"sniffing":{"enabled":true}}]}
JSON
if host_import; then exit 1; fi
[[ ! -e $SB_IMPORT_DIR/valid.json && -e $SB_IMPORT_DIR/unsupported.json ]]
jq -e '.=={inbounds:[{type:"vless",tag:"original",listen:"0.0.0.0",listen_port:12345,users:[{uuid:"00000000-0000-4000-8000-000000000001",name:"sample"}],transport:{type:"ws",path:"/sample",headers:{Host:"sample.test"}}}]}' "$SB_PARTS/import-valid.json" >/dev/null
cp "$SB_PARTS/import-valid.json" "$TMP/converted"
printf '%s\n' '{"inbounds":[{"protocol":"trojan","tag":"failed","port":12347,"settings":{"clients":[{"password":"sample"}]}}]}' >"$SB_IMPORT_DIR/failed.json"
if CHECK_FAIL=1 host_import; then exit 1; fi
[[ -e $SB_IMPORT_DIR/failed.json && ! -e $SB_PARTS/import-failed.json ]]
cmp "$TMP/converted" "$SB_PARTS/import-valid.json"

# test_tls_reality_http_import_and_failed_sources_are_preserved
(
    export SB_IMPORT_DIR="$TMP/secure-import"
    mkdir -p "$SB_IMPORT_DIR"
    cat >"$SB_IMPORT_DIR/tls-upgrade.json" <<'JSON'
{"inbounds":[{"tag":"tls-upgrade","protocol":"trojan","port":14001,"settings":{"clients":[{"password":"synthetic-password"}]},"streamSettings":{"network":"httpupgrade","security":"tls","tlsSettings":{"serverName":"tls.example","alpn":["http/1.1"],"certificates":[{"certificateFile":"/synthetic/cert.pem","keyFile":"/synthetic/key.pem","usage":"encipherment"}]},"httpupgradeSettings":{"path":"/upgrade","headers":{"Host":"tls.example"}}}}]}
JSON
    cat >"$SB_IMPORT_DIR/reality.json" <<'JSON'
{"inbounds":[{"tag":"reality","protocol":"vless","port":14002,"settings":{"decryption":"none","clients":[{"id":"00000000-0000-4000-8000-000000000002","flow":"xtls-rprx-vision"}]},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"dest":"[2001:db8::1]:8443","serverNames":["reality.example"],"privateKey":"synthetic-private-key","shortIds":["","0123456789abcdef"],"show":false,"xver":0}}}]}
JSON
    for network in http h2; do
        jq --arg network "$network" '.inbounds[0].tag=$network | .inbounds[0].port=(if $network=="http" then 14003 else 14004 end) | .inbounds[0].streamSettings.network=$network | .inbounds[0].streamSettings.tlsSettings.alpn=["h2"] | del(.inbounds[0].streamSettings.httpupgradeSettings) | .inbounds[0].streamSettings.httpSettings={host:["a.example","b.example"],path:"/h2",method:"POST",headers:{"X-Sample":["a","b"]}}' "$SB_IMPORT_DIR/tls-upgrade.json" >"$SB_IMPORT_DIR/$network.json"
    done
    cp "$SB_IMPORT_DIR/reality.json" "$TMP/reality-source.json"
    cp "$SB_IMPORT_DIR/tls-upgrade.json" "$TMP/tls-source.json"
    host_import
    [[ ! -e $SB_IMPORT_DIR/reality.json && ! -e $SB_IMPORT_DIR/tls-upgrade.json ]]
    jq -e '.inbounds[0] | .tls=={enabled:true,server_name:"tls.example",alpn:["http/1.1"],certificate_path:"/synthetic/cert.pem",key_path:"/synthetic/key.pem"} and .transport=={type:"httpupgrade",host:"tls.example",path:"/upgrade"}' "$SB_PARTS/import-tls-upgrade.json" >/dev/null
    jq -e '.inbounds[0] | .tls=={enabled:true,server_name:"reality.example",reality:{enabled:true,handshake:{server:"2001:db8::1",server_port:8443},private_key:"synthetic-private-key",short_id:["","0123456789abcdef"]}} and .users==[{uuid:"00000000-0000-4000-8000-000000000002",flow:"xtls-rprx-vision"}]' "$SB_PARTS/import-reality.json" >/dev/null
    for network in http h2; do
        jq -e '.inbounds[0].transport=={type:"http",host:["a.example","b.example"],path:"/h2",method:"POST",headers:{"X-Sample":["a","b"]}}' "$SB_PARTS/import-$network.json" >/dev/null
    done
    jq 'del(.inbounds[0].streamSettings.tlsSettings.serverName,.inbounds[0].streamSettings.tlsSettings.alpn)' "$TMP/tls-source.json" >"$TMP/tls-defaults.json"
    _host_convert_xray "$TMP/tls-defaults.json" "$TMP/tls-defaults-result.json"
    jq -e '.inbounds[0].tls | .alpn==["h2","http/1.1"] and (has("server_name")|not)' "$TMP/tls-defaults-result.json" >/dev/null
    jq '.inbounds[0].streamSettings.realitySettings |= (.target="handshake.example:443" | del(.dest))' "$TMP/reality-source.json" >"$TMP/target-alias.json"
    _host_convert_xray "$TMP/target-alias.json" "$TMP/target-result.json"
    jq -e '.inbounds[0].tls.reality.handshake=={server:"handshake.example",server_port:443}' "$TMP/target-result.json" >/dev/null
    # 即便核心替身会接受，也不能截断允许域名、证书或未知字段。
    jq '.inbounds[0].streamSettings.realitySettings.serverNames += ["second.example"]' "$TMP/reality-source.json" >"$SB_IMPORT_DIR/multiple-names.json"
    jq '.inbounds[0].streamSettings.realitySettings.maxClientVer="9.0.0"' "$TMP/reality-source.json" >"$SB_IMPORT_DIR/unknown-reality.json"
    jq '.inbounds[0].streamSettings.realitySettings.dest="/synthetic/socket"' "$TMP/reality-source.json" >"$SB_IMPORT_DIR/unix-dest.json"
    jq '.inbounds[0].streamSettings.tlsSettings.certificates += .inbounds[0].streamSettings.tlsSettings.certificates' "$TMP/tls-source.json" >"$SB_IMPORT_DIR/multiple-certificates.json"
    jq '.inbounds[0].streamSettings.tlsSettings.rejectUnknownSni=true' "$TMP/tls-source.json" >"$SB_IMPORT_DIR/unknown-tls.json"
    jq '.inbounds[0].streamSettings.httpupgradeSettings.headers["X-Extra"]="client-only"' "$TMP/tls-source.json" >"$SB_IMPORT_DIR/upgrade-client-header.json"
    jq '.inbounds[0].streamSettings.httpupgradeSettings.host="different.example"' "$TMP/tls-source.json" >"$SB_IMPORT_DIR/upgrade-host-conflict.json"
    jq '.inbounds[0].streamSettings.httpupgradeSettings.path="/upgrade?ed=2560"' "$TMP/tls-source.json" >"$SB_IMPORT_DIR/upgrade-early-data.json"
    jq '.inbounds[0].streamSettings={network:"h2",httpSettings:{path:"/h2"}}' "$TMP/tls-source.json" >"$SB_IMPORT_DIR/plain-h2.json"
    cp "$TMP/reality-source.json" "$SB_IMPORT_DIR/check-failed.json"
    cp "$SB_IMPORT_DIR/check-failed.json" "$TMP/check-failed-before.json"
    cp "$TMP/tls-source.json" "$SB_IMPORT_DIR/tls-check-failed.json"
    if CHECK_FAIL=1 host_import; then exit 1; fi
    cmp "$SB_IMPORT_DIR/check-failed.json" "$TMP/check-failed-before.json"
    cmp "$SB_IMPORT_DIR/tls-check-failed.json" "$TMP/tls-source.json"
    [[ ! -e $SB_PARTS/import-check-failed.json && ! -e $SB_PARTS/import-tls-check-failed.json ]]
    rm "$SB_IMPORT_DIR/tls-check-failed.json"
    rm "$SB_IMPORT_DIR/check-failed.json"
    for file in "$SB_IMPORT_DIR/"*.json; do cp "$file" "$TMP/$(basename "$file").before"; done
    if host_import; then exit 1; fi
    for file in "$SB_IMPORT_DIR/"*.json; do
        cmp "$file" "$TMP/$(basename "$file").before"
        [[ ! -e $SB_PARTS/import-$(basename "$file") ]]
    done
)

# test_official_release_metadata_archive_and_digest_without_network
(
    uname() { case ${1:-} in -s) printf 'Linux\n';; -m) printf 'x86_64\n';; *) command uname "$@";; esac; }
    mkdir -p "$TMP/release/sing-box-1.14.4-linux-amd64"
    cp "$SB_CORE" "$TMP/release/sing-box-1.14.4-linux-amd64/sing-box"
    cp "$SB_CADDY" "$TMP/release/caddy"
    tar -czf "$TMP/release/core.tar.gz" -C "$TMP/release" sing-box-1.14.4-linux-amd64/sing-box
    tar -czf "$TMP/release/caddy.tar.gz" -C "$TMP/release" caddy
    _host_download() {
        local repo asset tag archive digest
        case $1 in
            https://api.github.com/repos/SagerNet/*) repo=SagerNet/sing-box; asset=sing-box-1.14.4-linux-amd64.tar.gz; tag=v1.14.4; archive="$TMP/release/core.tar.gz";;
            https://api.github.com/repos/caddyserver/*) repo=caddyserver/caddy; asset=caddy_2.0.0_linux_amd64.tar.gz; tag=v2.0.0; archive="$TMP/release/caddy.tar.gz";;
            https://github.com/SagerNet/*) cp "$TMP/release/core.tar.gz" "$2"; return;;
            https://github.com/caddyserver/*) cp "$TMP/release/caddy.tar.gz" "$2"; return;;
            *) return 1;;
        esac
        digest="sha256:$(sha256sum "$archive" | cut -d ' ' -f 1)"
        [[ ${BAD_DIGEST:-0} == 0 ]] || digest=sha256:bad
        jq -n --arg tag "$tag" --arg asset "$asset" --arg digest "$digest" --arg url "https://github.com/$repo/releases/download/$tag/$asset" '{tag_name:$tag,assets:[{name:$asset,digest:$digest,browser_download_url:$url}]}' >"$2"
    }
    host_update core 1.14.4
    host_update caddy
    cp "$SB_CORE" "$TMP/release/core-before"
    if BAD_DIGEST=1 host_update core 1.14.4; then exit 1; fi
    cmp "$SB_CORE" "$TMP/release/core-before"
)

# test_failed_update_preserves_binary
cp "$SB_CORE" "$TMP/core-before"
_host_release() { printf 'broken' >"$3"; return 1; }
if host_update core 1.14.4; then exit 1; fi
cmp "$SB_CORE" "$TMP/core-before"

# test_cancel_has_no_mutations
if host_uninstall </dev/null; then exit 1; fi
if host_reinstall </dev/null; then exit 1; fi
if host_bbr </dev/null; then exit 1; fi
cmp "$SB_CORE" "$TMP/core-before"

# test_installer_adopt_and_fresh_use_only_independent_artifacts
SOURCE="$TMP/source"
mkdir -p "$SOURCE/lib"
cp "$PROJECT/install.sh" "$SOURCE/install.sh"
cp "$PROJECT/lib/host.sh" "$SOURCE/lib/host.sh"
for file in sb VERSION README.md LICENSE SOURCES.md REQUIREMENTS.md CONTRACTS.md lib/documents.sh lib/frontend.sh lib/forms.sh lib/schema.jq lib/nodes.sh lib/links.jq lib/cli.sh; do printf 'synthetic MIT fixture\n' >"$SOURCE/$file"; done
cat >"$SOURCE/lib/common.sh" <<'COMMON'
fail() { printf '%s\n' "$*" >&2; return 1; }
read_text() { local value; IFS= read -r value || return; printf '%s\n' "$value"; }
json_temp() { mktemp "$SB_WORK/json.XXXXXX"; }
runtime_init() { :; }
COMMON
printf 'must not copy\n' >"$SOURCE/old.sh"
export TEST_TEMP_ROOT="$TMP"
cp "$SB_MAIN" "$TMP/main-before"
cp "$SB_META" "$TMP/meta-before"
cp "$SB_PARTS/keep.json" "$TMP/part-before"
printf '4321\n' >"$SB_ROOT/runtime.pid"
: >"$CALLS"
if SB_BIN_DIR="$TMP/mismatch-bin" bash "$SOURCE/install.sh" --adopt wrong.example; then exit 1; fi
[[ ! -e $TMP/mismatch-bin ]]
bash "$SOURCE/install.sh" --adopt original.example
cmp "$SB_MAIN" "$TMP/main-before"
cmp "$SB_META" "$TMP/meta-before"
cmp "$SB_PARTS/keep.json" "$TMP/part-before"
for document in SOURCES.md REQUIREMENTS.md CONTRACTS.md; do cmp "$SOURCE/$document" "$SB_ROOT/manager/$document"; done
[[ $(cat "$SB_ROOT/runtime.pid") == 4321 ]]
[[ -e $SB_BIN_DIR/sb && -e $SB_BIN_DIR/sing-box && ! -e $SB_ROOT/manager/old.sh ]]
if [[ $(uname -s) != MINGW* ]]; then
    [[ -L $SB_BIN_DIR/sb && -L $SB_BIN_DIR/sing-box ]]
fi
[[ -f $SB_ROOT/manager/.independent-manager && -f $SOURCE/install.sh ]]
# 无任何服务调用，只有核心校验。
[[ $(wc -l <"$CALLS") == 1 ]]
cp "$SB_ROOT/manager/lib/host.sh" "$TMP/manager-before"
if CORE_FAIL=1 SB_BIN_DIR="$TMP/fail-bin" bash "$SOURCE/install.sh" --adopt; then exit 1; fi
[[ ! -e $TMP/fail-bin ]]
cmp "$SB_ROOT/manager/lib/host.sh" "$TMP/manager-before"
FRESH="$TMP/fresh"
SB_ROOT="$FRESH" SB_CORE="$FRESH/bin/sing-box" SB_MAIN="$FRESH/config.json" SB_PARTS="$FRESH/conf" SB_META="$FRESH/script.json" SB_BIN_DIR="$TMP/fresh-bin" bash "$SOURCE/install.sh" --core-file "$TMP/core-before" fresh.example
jq -e '.=={log:{level:"info"},dns:{servers:[]},inbounds:[],outbounds:[{type:"direct",tag:"direct"}]}' "$FRESH/config.json" >/dev/null
jq -e '.=={server:"fresh.example"}' "$FRESH/script.json" >/dev/null
[[ -f $SOURCE/install.sh && -x $FRESH/bin/sing-box && -e $TMP/fresh-bin/sb ]]
if [[ $(uname -s) != MINGW* ]]; then [[ -L $TMP/fresh-bin/sb ]]; fi
if SB_ROOT="$TMP/cancel" SB_CORE="$TMP/cancel/bin/sing-box" SB_MAIN="$TMP/cancel/config.json" SB_PARTS="$TMP/cancel/conf" SB_META="$TMP/cancel/script.json" SB_BIN_DIR="$TMP/cancel-bin" bash "$SOURCE/install.sh" --core-file "$TMP/core-before" </dev/null; then exit 1; fi
[[ ! -e $TMP/cancel ]]
# test_authored_service_units_with_stub_managers
export -f systemctl rc-service rc-update
for manager in systemd openrc; do
    root="$TMP/unit-$manager"
    SB_ROOT="$root" SB_CORE="$root/bin/sing-box" SB_MAIN="$root/config.json" SB_PARTS="$root/conf" SB_META="$root/script.json" SB_BIN_DIR="$TMP/bin-$manager" SB_SERVICE_MANAGER="$manager" SB_SYSTEMD_DIR="$TMP/systemd" SB_OPENRC_DIR="$TMP/init.d" bash "$SOURCE/install.sh" --core-file "$TMP/core-before" unit.example
done
[[ -f $TMP/systemd/sing-box.service && -x $TMP/init.d/sing-box ]]
bash -n "$TMP/init.d/sing-box"
[[ -d $SB_WORK ]]
# test_archive_and_short_install_options
mkdir -p "$TMP/archive/sing-box-synthetic"
cp "$TMP/core-before" "$TMP/archive/sing-box-synthetic/sing-box"
tar -czf "$TMP/core.tar.gz" -C "$TMP/archive" sing-box-synthetic/sing-box
root="$TMP/archive-install"
SB_ROOT="$root" SB_CORE="$root/bin/sing-box" SB_MAIN="$root/config.json" SB_PARTS="$root/conf" SB_META="$root/script.json" SB_BIN_DIR="$TMP/archive-bin" bash "$SOURCE/install.sh" -f "$TMP/core.tar.gz" -v 1.14.4 -p https://proxy.invalid archive.example
cmp "$TMP/core-before" "$root/bin/sing-box"
if printf '' | SB_BIN_DIR="$TMP/reinstall-cancel-bin" bash "$SOURCE/install.sh" --reinstall --core-file "$TMP/core-before" original.example; then exit 1; fi
cmp "$SB_MAIN" "$TMP/main-before"
# test_real_core_in_isolated_config_when_supplied
if [[ -n ${TEST_CORE:-} ]]; then
    jq -n '{log:{level:"info"},dns:{servers:[]},inbounds:[],outbounds:[{type:"direct",tag:"direct"}]}' >"$TMP/real-config.json"
    "$TEST_CORE" check -c "$TMP/real-config.json"
fi
printf 'host tests passed\n'
