#!/usr/bin/env bash
# 使用真实程序检查候选；所有目录和服务操作隔离于生产环境。
set -euo pipefail
: "${TEST_CORE:?Provide a real sing-box executable}"
: "${TEST_CADDY:?Provide a real Caddy executable}"
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
sandbox=$(mktemp -d)
trap 'rm -rf -- "$sandbox"' EXIT
export SB_ROOT=$sandbox/runtime SB_CORE=$TEST_CORE SB_CADDY=$TEST_CADDY
export SB_CADDY_ROOT=$sandbox/frontend SB_SERVICE_MANAGER=none SB_BIN_DIR=$sandbox/commands
mkdir -p "$SB_ROOT/conf" "$SB_CADDY_ROOT/sing-box" "$SB_CADDY_ROOT/sites" "$SB_BIN_DIR"
cat >"$SB_ROOT/config.json" <<'JSON'
{"log":{"level":"error","timestamp":true},"dns":{"servers":[{"type":"udp","tag":"resolver-a","server":"1.1.1.1"},{"type":"local","tag":"resolver-b"}],"rules":[{"domain":["integration.invalid"],"server":"resolver-a"}]},"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct","default_domain_resolver":"resolver-a"}}
JSON
cat >"$SB_ROOT/script.json" <<'JSON'
{"server":"192.0.2.101"}
JSON
cat >"$SB_ROOT/conf/front.json" <<'JSON'
{"inbounds":[{"type":"trojan","tag":"edge","listen":"127.0.0.1","listen_port":32101,"users":[{"password":"pass \" # / value"}],"transport":{"type":"ws","path":"/entry","headers":{"X-Example":"untouched"},"max_early_data":1024,"early_data_header_name":"Sec-WebSocket-Protocol"}}]}
JSON
cat >"$SB_ROOT/conf/other.json" <<'JSON'
{"inbounds":[{"type":"http","tag":"local-http","listen":"127.0.0.1","listen_port":32103},{"type":"socks","tag":"local-socks","listen":"127.0.0.1","listen_port":32104,"users":[{"username":"u","password":"p"}]}]}
JSON
cat >"$SB_CADDY_ROOT/Caddyfile" <<EOF
{
    admin off
}
import $SB_CADDY_ROOT/sing-box/*.conf
import $SB_CADDY_ROOT/sites/*.conf
EOF
cat >"$SB_CADDY_ROOT/sing-box/front.example.conf" <<EOF
front.example:443 {
    handle /entry {
        reverse_proxy 127.0.0.1:32101
    }
    import $SB_CADDY_ROOT/sing-box/front.example.conf.add
}
EOF
printf 'header X-Preserved true\n' >"$SB_CADDY_ROOT/sing-box/front.example.conf.add"
cli() {
    if ! bash "$project/sb" "$@" >"$sandbox/output" 2>"$sandbox/error"; then
        cat "$sandbox/error" >&2
        printf 'FAIL: %s\n' "$*" >&2
        return 1
    fi
}
cli test
cli url edge
grep -q '^trojan://.*@front.example:443?' "$sandbox/output"
grep -q 'ed=1024' "$sandbox/output"
cli port edge 9443
jq -e '.inbounds[0].listen_port==32101' "$SB_ROOT/conf/front.json" >/dev/null
cli url edge
grep -q '@front.example:9443?' "$sandbox/output"
cli change edge settings listen_port 32102
jq -e '.inbounds[0].listen_port==32102' "$SB_ROOT/conf/front.json" >/dev/null
"$SB_CADDY" adapt --config "$SB_CADDY_ROOT/Caddyfile" --adapter caddyfile >"$sandbox/caddy.json" 2>"$sandbox/caddy.log"
jq -e '[.. | objects | .dial? // empty] | any(. == "127.0.0.1:32102")' "$sandbox/caddy.json" >/dev/null
cli path edge /next
jq -e '.inbounds[0].transport.path=="/next" and .inbounds[0].transport.headers["X-Example"]=="untouched" and .inbounds[0].users[0].password=="pass \" # / value"' "$SB_ROOT/conf/front.json" >/dev/null
[[ $(cat "$SB_CADDY_ROOT/sing-box/front.example.conf.add") == 'header X-Preserved true' ]]
printf 'PASS: real_frontend_public_and_backend_edits\n'
cp "$SB_ROOT/conf/front.json" "$sandbox/before.json"
if bash "$project/sb" change edge settings listen_port 70000 >"$sandbox/output" 2>&1; then
    printf 'FAIL: accepted out-of-range port\n' >&2; exit 1
fi
cmp "$sandbox/before.json" "$SB_ROOT/conf/front.json"
cli dns change resolver-a server 8.8.8.8
jq -e '.dns.servers[0].server=="8.8.8.8" and .dns.rules[0].server=="resolver-a"' "$SB_ROOT/config.json" >/dev/null
cp "$SB_ROOT/config.json" "$sandbox/dns-before.json"
if bash "$project/sb" dns del resolver-a >"$sandbox/output" 2>&1; then
    printf 'FAIL: deleted referenced resolver\n' >&2; exit 1
fi
cmp "$sandbox/dns-before.json" "$SB_ROOT/config.json"
cli dns settings reverse_mapping on
jq -e '.dns.reverse_mapping==true' "$SB_ROOT/config.json" >/dev/null
cli info local-http settings
cli change local-http settings tcp_fast_open off
jq -e '.inbounds[0].tcp_fast_open==false and .inbounds[1].tag=="local-socks"' "$SB_ROOT/conf/other.json" >/dev/null
cli del local-http
jq -e '.inbounds|length==1 and .[0].tag=="local-socks"' "$SB_ROOT/conf/other.json" >/dev/null
printf 'PASS: real_document_references_and_field_preservation\n'

mkdir -p "$SB_ROOT/certificates"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 -subj /CN=relative.test -keyout "$SB_ROOT/certificates/key.pem" -out "$SB_ROOT/certificates/cert.pem" >/dev/null 2>&1
jq -n '{inbounds:[{type:"http",tag:"relative-tls",listen:"127.0.0.1",listen_port:32105,tls:{enabled:true,certificate_path:"certificates/cert.pem",key_path:"certificates/key.pem"}}]}' >"$SB_ROOT/conf/relative.json"
(cd "$sandbox"; cli test)
(cd "$sandbox"; cli info relative-tls)
printf 'PASS: service_working_directory_for_relative_certificates\n'
before=$(sha256sum "$SB_ROOT/config.json" "$SB_ROOT"/conf/*.json "$SB_ROOT/script.json")
if ! bash "$project/install.sh" --adopt 192.0.2.101 >"$sandbox/install.log" 2>&1; then
    cat "$sandbox/install.log" >&2; exit 1
fi
[[ $before == "$(sha256sum "$SB_ROOT/config.json" "$SB_ROOT"/conf/*.json "$SB_ROOT/script.json")" ]]
cmp "$project/LICENSE" "$SB_ROOT/manager/LICENSE"
cmp "$project/VERSION" "$SB_ROOT/manager/VERSION"
"$SB_BIN_DIR/sb" url edge >"$sandbox/installed-uri"
grep -q '@front.example:9443?' "$sandbox/installed-uri"
printf 'PASS: independent_installation_and_command_symlink\n'
