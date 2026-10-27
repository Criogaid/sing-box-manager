#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1
SB_PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$SB_PROJECT/lib/common.sh"
source "$SB_PROJECT/lib/nodes.sh"
case ${OSTYPE:-} in msys*|cygwin*) jq() { command jq -b "$@"; } ;; esac
sandbox=$(mktemp -d)
case ${OSTYPE:-} in msys*|cygwin*) sandbox=$(cygpath -m "$sandbox"); SB_PROJECT=$(cygpath -m "$SB_PROJECT") ;; esac
trap 'rm -rf -- "$sandbox"' EXIT
SB_ROOT=$sandbox/root SB_WORK=$sandbox/work SB_SERVICE_MANAGER=none
mkdir -p "$SB_ROOT/conf" "$SB_WORK"
runtime_init
SB_AUTO_FRONTEND=0
new_id() { local h; h=$(openssl rand -hex 16); printf '%s-%s-4%s-8%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"; }
free_port() { printf '23456\n'; }
server_address() { printf '2001:db8::1\n'; }
host_service() { printf '%s\n' "$*" >> "$sandbox/services"; }
forms_init() { :; }
forms_types() { printf '%s\n' socks shadowsocks trojan vmess vless direct tuic hysteria2 anytls shadowtls http; }
forms_definition() { printf '{"title":"%s"}\n' "$1"; }
forms_set() {
    local temp=$SB_WORK/form
    jq --arg p "$3" --arg v "$4" 'setpath($p|split("."); if $v|test("^[0-9]+$") then $v|tonumber else $v end)' "$2" > "$temp"
    cp "$temp" "$2"
}
forms_edit() {
    [[ ${CANCEL_FORM:-0} == 0 ]] || return 1
    local temp=$SB_WORK/form
    if [[ $1 == *Config* ]]; then
        jq '.dns={servers:[{type:"local",tag:"related"}],rules:[{domain:"synthetic.example",server:"related"}]}' "$2" > "$temp"
    elif [[ $1 == *DNSServer* ]]; then
        jq '. + {tag:"new-dns",server:"203.0.113.53"}' "$2" > "$temp"
    else jq '. + {tag:(.tag // "form-node"),listen_port:(.listen_port // 12345)}' "$2" > "$temp"; fi
    cp "$temp" "$2"
}
forms_show() { jq 'walk(if type=="object" and has("private_key") then .private_key="[隐藏]" else . end)' "$1"; }
documents_list() { printf '%s\0' "$SB_MAIN"; local file; for file in "$SB_PARTS"/*.json; do [[ ! -f $file ]] || printf '%s\0' "$file"; done; }
documents_inventory() {
    local -a files=()
    mapfile -d '' -t files < <(documents_list)
    jq -n '[inputs | input_filename as $f | .inbounds // [] | to_entries[] | {file:$f,index:.key,value:.value}]' "${files[@]}"
}
documents_select() {
    local all found
    all=$(documents_inventory)
    found=$(jq --arg t "${1:-}" '[.[]|select(.value.tag==$t)]' <<< "$all")
    [[ $(jq length <<< "$found") == 1 ]] || return 1
    jq '.[0]' <<< "$found"
}
documents_commit() {
    [[ ${REJECT:-0} == 0 ]] || return 1
    cp "$2" "$1"
    printf '%s\n' "$1" >> "$sandbox/commits"
}
frontend_lookup() { jq -e '.type and (has("inbounds")|not)' "$1" >/dev/null || return; if [[ ${FRONT:-0} == 1 ]]; then printf '{"file":"synthetic.conf","host":"front.example","port":8443,"backend":10001,"path":"/live","transport":"ws"}\n'; else printf 'null\n'; fi; }
frontend_edit() { jq -e '.type and (has("inbounds")|not)' "$1" >/dev/null || return; printf '%s\n' "$2=$3" >> "$sandbox/front"; }
frontend_create() { jq -e '.type and .listen=="127.0.0.1" and (.tls.enabled!=true)' "$1" >/dev/null || return; printf '%s\n' "$4" >> "$sandbox/create"; }
reset_fixture() {
    rm -f "$SB_PARTS"/*.json
    cat > "$SB_MAIN" <<'JSON'
{"log":{"level":"warn","output":"keep.log"},"route":{"rules":[]},"unknown":{"keep":[1,"x"]},"dns":{"servers":[{"type":"udp","tag":"root-dns","server":"192.0.2.53"}],"rules":[{"domain":"keep.example","server":"root-dns"}],"final":"root-dns"},"inbounds":[{"type":"socks","tag":"socks","listen":"::","listen_port":10001,"users":[{"username":"a:@ /中","password":"p@:#?&/+中"}]},{"type":"trojan","tag":"ws","listen":"127.0.0.1","listen_port":10002,"users":[{"password":"p@:#?&/+中"}],"transport":{"type":"ws","path":"/a?b=&中","max_early_data":1024,"early_data_header_name":"Sec-WebSocket-Protocol"}},{"type":"anytls","tag":"any","listen_port":10003,"users":[{"password":"secret"}],"tls":{"enabled":true,"acme":{"domain":["acme.example"]}}},{"type":"direct","tag":"direct","listen_port":10004,"override_address":"before.example","override_port":80}]}
JSON
    printf '{"dns":{"servers":[{"type":"tcp","tag":"part-dns","server":"192.0.2.54"}],"strategy":"ipv4_only"},"extra":true}' > "$SB_PARTS/dns.json"
}
assert_json() { jq -e "$2" "$1" >/dev/null; }
reset_fixture
before=$(jq 'del(.inbounds[0].listen_port)' "$SB_MAIN")
node_change socks port 25000
[[ $(jq 'del(.inbounds[0].listen_port)' "$SB_MAIN") == "$before" ]]
assert_json "$SB_MAIN" '.inbounds[0].listen_port==25000'
node_change direct door-port 443
node_change direct door-addr after.example
assert_json "$SB_MAIN" '.inbounds[3].override_port==443 and .inbounds[3].override_address=="after.example"'
node_change socks username 'new:@ user'
node_change socks passwd 'special:@/?#&中'
assert_json "$SB_MAIN" '.inbounds[0].users[0]=={username:"new:@ user",password:"special:@/?#&中"}'
uri=$(node_url socks)
auth=$(printf '%s' 'new:@ user:special:@/?#&中' | openssl base64 -A)
[[ $uri == "socks://$auth@[2001:db8::1]:25000#socks" ]]
FRONT=1
node_change ws port 9443
[[ $(cat "$sandbox/front") == port=9443 ]]
assert_json "$SB_MAIN" '.inbounds[1].listen_port==10002'
node_change ws settings listen_port 20002
node_change ws path '/changed &中'
assert_json "$SB_MAIN" '.inbounds[1].listen_port==20002 and .inbounds[1].transport.path=="/changed &中"'
uri=$(node_url ws)
[[ $uri == *'@front.example:8443?'* && $uri == *'security=tls'* && $uri == *'path=%2Flive'* && $uri == *'ed=1024'* && $uri == *'eh=Sec-WebSocket-Protocol'* ]]
FRONT=0
[[ $(node_url any) == *'sni=acme.example'* ]]
state=$(cat "$SB_MAIN")
if node_change socks port 0; then exit 1; fi
REJECT=1
if node_change socks port 33333; then exit 1; fi
REJECT=0
[[ $(cat "$SB_MAIN") == "$state" ]]
CANCEL_FORM=1
if node_change socks settings; then exit 1; fi
CANCEL_FORM=0
[[ $(cat "$SB_MAIN") == "$state" ]]
# 两用户必须选择；EOF 不能改任一账户。
jq '.inbounds[0].users += [{username:"second",password:"untouched"}]' "$SB_MAIN" > "$SB_WORK/two"
cp "$SB_WORK/two" "$SB_MAIN"
state=$(cat "$SB_MAIN")
if node_change socks passwd changed < /dev/null; then exit 1; fi
[[ $(cat "$SB_MAIN") == "$state" ]]
node_change socks passwd chosen <<< '2'
assert_json "$SB_MAIN" '.inbounds[0].users[1].password=="chosen" and .inbounds[0].users[0].password=="special:@/?#&中"'
reset_fixture
# 私钥、公钥关系独立用 OpenSSL 生成并比对，不依赖缓存。
openssl genpkey -algorithm X25519 -out "$SB_WORK/key.pem"
openssl pkey -in "$SB_WORK/key.pem" -outform DER -out "$SB_WORK/key.der"
openssl pkey -in "$SB_WORK/key.pem" -pubout -outform DER -out "$SB_WORK/pub.der"
private=$(tail -c 32 "$SB_WORK/key.der" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
public=$(tail -c 32 "$SB_WORK/pub.der" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
[[ $(_node_public "$private") == "$public" ]]
jq --arg key "$private" '.inbounds += [{type:"vless",tag:"reality",listen_port:10443,users:[{uuid:"00000000-0000-4000-8000-000000000001",flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:"real.example",reality:{enabled:true,private_key:$key,public_key:"STALE",handshake:{server:"real.example",server_port:443},short_id:["abcd","ef01"]}}}]' "$SB_MAIN" > "$SB_WORK/reality"
cp "$SB_WORK/reality" "$SB_MAIN"
uri=$(node_url reality)
[[ $uri == *"pbk=$public"* && $uri != *STALE* && $uri != *"$private"* && $uri == *sid=abcd* && $uri == *flow=xtls-rprx-vision* ]]
[[ $(node_info reality) != *"$private"* ]]
node_change reality key auto
assert_json "$SB_MAIN" '.inbounds[4].tls.reality.private_key | length==43'
node_add shadowtls tag outer port 10444 host handshake.example passwd 'outer;=:\secret' inner-password 'inner:@中'
uri=$(node_url outer)
shadow=$(jq -nr '{version:"3",host:"handshake.example",password:"outer;=:\\secret"}|tojson|@base64|@uri')
[[ $uri == ss://* && $uri == *"shadow-tls=$shadow#outer" && $uri != *'inner:@中'* ]]
file=$(documents_select outer | jq -r .file)
assert_json "$file" '.inbounds|length==2'
node_delete outer
assert_json "$file" '.inbounds|length==0'
node_add ss tag ss-special port 10099 passwd 'a:+/中'
uri=$(node_url ss-special)
auth=$(printf '%s' '2022-blake3-aes-128-gcm:a:+/中' | openssl base64 -A | tr '+/' '-_' | tr -d '=')
[[ $uri == "ss://$auth@"* ]]
# 添加与关联 DNS 在同一候选文档；生成模式不写活动文件。
count=$(wc -l < "$sandbox/commits")
SB_GENERATE=1
node_add vmess tag generated port 12345 +form > "$SB_WORK/generated"
assert_json "$SB_WORK/generated" '.inbounds[0].tag=="generated" and .dns.servers[0].tag=="related"'
[[ $(wc -l < "$sandbox/commits") == "$count" ]]
SB_GENERATE=0
state=$(cat "$SB_MAIN")
if node_add ss unexpected-old-arg; then exit 1; fi
if node_add ss < /dev/null; then exit 1; fi
[[ $(cat "$SB_MAIN") == "$state" ]]
reset_fixture
original=$(jq 'del(.dns.servers[0].server)' "$SB_PARTS/dns.json")
dns_command change part-dns server 203.0.113.54
[[ $(jq 'del(.dns.servers[0].server)' "$SB_PARTS/dns.json") == "$original" ]]
assert_json "$SB_PARTS/dns.json" '.dns.servers[0].server=="203.0.113.54"'
dns_command settings strategy prefer_ipv4
assert_json "$SB_MAIN" '.dns.strategy=="prefer_ipv4" and .dns.rules[0].server=="root-dns"'
dns_command add udp
dns_command del new-dns
assert_json "$SB_MAIN" '.dns.servers|length==1'
dns_command del part-dns
assert_json "$SB_PARTS/dns.json" '.dns.servers==[] and .extra==true and .dns.strategy=="ipv4_only"'
# 删除同文件节点保留其他节点及根字段。
node_delete ws
assert_json "$SB_MAIN" '.inbounds|length==3'
assert_json "$SB_MAIN" '.unknown.keep==[1,"x"] and .log.output=="keep.log" and .dns.rules[0].server=="root-dns"'
[[ ! -e $sandbox/services ]]
# 完整表单必须从 Config 根开始，以便同候选编辑关联 DNS。
SB_GENERATE=1
node_add inbound http <<< 'full-form' > "$SB_WORK/full"
assert_json "$SB_WORK/full" '.inbounds[0].type=="http" and .inbounds[0].tag=="full-form" and .dns.servers[0].tag=="related"'
SB_GENERATE=0
SB_AUTO_FRONTEND=1
node_add tws tag front-created port 24443 host front.example
[[ $(cat "$sandbox/create") == $'check\napply' ]]
SB_AUTO_FRONTEND=0
node_add vmess-ws tag vmess-export port 20001 path '/测试?x=&'
uri=$(node_url vmess-export)
printf '%s' "${uri#vmess://}" | openssl base64 -d -A > "$SB_WORK/vmess"
assert_json "$SB_WORK/vmess" '.v=="2" and .net=="ws" and .path=="/测试?x=&" and .add=="2001:db8::1" and .aid==0'
for preset in tuic hysteria2 anytls trojan; do
    node_add "$preset" tag "self-$preset" port 24444 host self.example
    file=$(documents_select "self-$preset" | jq -r .file)
    assert_json "$file" '.inbounds[0].tls.certificate[0]=="-----BEGIN CERTIFICATE-----" and .inbounds[0].tls.key[0]=="-----BEGIN PRIVATE KEY-----" and (.inbounds[0].tls|has("acme")|not)'
    [[ $(node_info "self-$preset" settings) != *'BEGIN PRIVATE KEY'* ]]
    uri=$(node_url "self-$preset")
    case $preset in tuic) [[ $uri == *allow_insecure=1* ]] ;; trojan) [[ $uri == *allowInsecure=1* ]] ;; *) [[ $uri == *insecure=1* ]] ;; esac
    [[ $(node_info "self-$preset") != *'BEGIN PRIVATE KEY'* ]]
done
node_add anytls tag provider port 24445 host provider.example tls acme
[[ $(node_url provider) == *sni=provider.example* ]]
file=$(documents_select provider | jq -r .file)
assert_json "$file" '.inbounds[0].tls.certificate_provider=={type:"acme",domain:["provider.example"]}'
node_add shadowtls tag shared port 24446 host cover.example
file=$(documents_select shared | jq -r .file)
jq '.inbounds += [{type:"shadowtls",tag:"second-outer",listen_port:24447,detour:"shared-inner",version:2,password:"outer",handshake:{server:"cover.example",server_port:443}}]' "$file" > "$SB_WORK/shared"
cp "$SB_WORK/shared" "$file"
node_delete shared
assert_json "$file" '[.inbounds[].tag]==["shared-inner","second-outer"]'
node_change second-outer new socks tag replacement port 24448
assert_json "$file" '[.inbounds[].tag]==["second-outer"] and .inbounds[0].type=="socks"'
if node_url direct; then exit 1; fi
node_info direct > "$SB_WORK/direct-info"
assert_json "$SB_WORK/direct-info" '.inbound.type=="direct"'
# 更换为原生 TLS 协议时保留 TLS，不继承旧 Caddy 的明文后端设置。
reset_fixture
FRONT=1
node_change ws new vless-reality tag ignored port 25556 host reality.example
assert_json "$SB_MAIN" '.inbounds[1].type=="vless" and .inbounds[1].tls.reality.enabled and .inbounds[1].listen=="::"'
FRONT=0
qrencode() { [[ $1 == -t && $2 == ANSIUTF8 && $3 == -- ]]; printf '%s\n' "$4" > "$SB_WORK/qr-uri"; }
node_qr socks
[[ $(cat "$SB_WORK/qr-uri") == "$(node_url socks)" ]]
# 显式 early-data 字段独立导出，零值与缺省值不能混淆。
reset_fixture
jq 'del(.inbounds[1].transport.max_early_data)' "$SB_MAIN" > "$SB_WORK/no-ed"
cp "$SB_WORK/no-ed" "$SB_MAIN"
uri=$(node_url ws)
[[ $uri == *eh=Sec-WebSocket-Protocol* && $uri != *'ed='* ]]
jq '.inbounds[1].transport.max_early_data=0' "$SB_MAIN" > "$SB_WORK/zero-ed"
cp "$SB_WORK/zero-ed" "$SB_MAIN"
uri=$(node_url ws)
[[ $uri == *ed=0* && $uri == *eh=Sec-WebSocket-Protocol* ]]
# DNS 只追加或选择服务器；none 清除 final，保留规则和所有引用目标。
original=$(jq 'del(.dns.final,.dns.servers)' "$SB_MAIN")
part_before=$(cat "$SB_PARTS/dns.json")
dns_command set https://resolver.example:443/custom-query
assert_json "$SB_MAIN" '.dns.servers[0].tag=="root-dns" and .dns.servers[1].type=="local" and .dns.servers[2].type=="https" and .dns.servers[2].path=="/custom-query" and .dns.servers[2].domain_resolver==.dns.servers[1].tag and .dns.final==.dns.servers[2].tag'
[[ $(jq 'del(.dns.final,.dns.servers)' "$SB_MAIN") == "$original" && $(cat "$SB_PARTS/dns.json") == "$part_before" ]]
dns_command set https://resolver.example:443/custom-query
assert_json "$SB_MAIN" '.dns.servers|length==3'
servers=$(jq '.dns.servers' "$SB_MAIN")
dns_command none
assert_json "$SB_MAIN" '.dns|has("final")|not'
[[ $(jq '.dns.servers' "$SB_MAIN") == "$servers" ]]
dns_command set 'tls://[2001:db8::53]:8853'
assert_json "$SB_MAIN" '.dns.servers[-1].type=="tls" and .dns.servers[-1].server=="2001:db8::53" and .dns.servers[-1].server_port==8853'
dns_command set 192.0.2.55
assert_json "$SB_MAIN" '.dns.servers[-1].type=="udp" and .dns.servers[-1].server=="192.0.2.55" and .dns.servers[-1].server_port==53'
dns_command set local
assert_json "$SB_MAIN" '.dns.final==.dns.servers[1].tag'
state=$(cat "$SB_MAIN")
for invalid in '999.0.0.1' 'udp://192.0.2.1:0' '{"server":"192.0.2.1"}' 'https://name..example/query'; do
    if dns_command set "$invalid"; then exit 1; fi
done
if dns_command set < /dev/null; then exit 1; fi
[[ $(cat "$SB_MAIN") == "$state" ]]
# method 的密钥长度及多用户密码必须随算法共同迁移。
node_add ss tag rotation port 25557 method aes-128-gcm passwd original
file=$(documents_select rotation | jq -r .file)
node_change rotation method 2022-blake3-aes-256-gcm
password=$(jq -r '.inbounds[0].password' "$file")
[[ $(printf '%s' "$password" | openssl base64 -d -A | wc -c) == 32 ]]
jq '.inbounds[0].users=[{name:"one",password:"before-one"},{name:"two",password:"before-two"}]' "$file" > "$SB_WORK/ss-users"
cp "$SB_WORK/ss-users" "$file"
node_change rotation method auto
assert_json "$file" '.inbounds[0].method=="2022-blake3-aes-128-gcm" and [.inbounds[0].users[].name]==["one","two"] and .inbounds[0].users[0].password!=.inbounds[0].users[1].password'
while IFS= read -r password; do
    [[ $(printf '%s' "$password" | openssl base64 -d -A | wc -c) == 16 ]]
done < <(jq -r '.inbounds[0] | .password,.users[].password' "$file")
state=$(cat "$file")
if node_change rotation method aes-256-gcm; then exit 1; fi
[[ $(cat "$file") == "$state" ]]
# full 共用预设构建器，保留同文档其他节点和根配置。
original=$(jq 'del(.inbounds[0])' "$SB_MAIN")
node_change socks full 25558 username path
assert_json "$SB_MAIN" '.inbounds[0].tag=="socks" and .inbounds[0].listen_port==25558 and .inbounds[0].users[0]=={username:"username",password:"path"}'
[[ $(jq 'del(.inbounds[0])' "$SB_MAIN") == "$original" ]]
node_change ws new rh2 25559 auto cover.example
assert_json "$SB_MAIN" '.inbounds[1].tag=="ws" and .inbounds[1].transport.type=="http" and .inbounds[1].tls.reality.enabled and (.inbounds[1].users[0]|has("flow")|not)'
[[ $(node_url ws) == *type=h2* ]]
node_change ws key "$private" "$public"
assert_json "$SB_MAIN" '.inbounds[1].tls.reality|has("public_key")|not'
state=$(cat "$SB_MAIN")
if node_change ws key "$private" invalid-public; then exit 1; fi
[[ $(cat "$SB_MAIN") == "$state" ]]
node_change ws sni auto
assert_json "$SB_MAIN" '.inbounds[1].tls.server_name=="www.microsoft.com" and .inbounds[1].tls.reality.handshake.server==.inbounds[1].tls.server_name'
node_change ws full 25560 auto other-cover.example
assert_json "$SB_MAIN" '.inbounds[1].tag=="ws" and .inbounds[1].transport.type=="http" and .inbounds[1].tls.reality.handshake.server=="other-cover.example"'
node_change ws new shadowtls tag ignored port 25561 host cover.example
assert_json "$SB_MAIN" '.inbounds[1].tag=="ws" and .inbounds[1].detour=="ws-inner" and .inbounds[2].tag=="ws-inner"'
jq '.inbounds += [{type:"shadowtls",tag:"other",listen_port:25562,detour:"ws-inner",version:2,password:"outer",handshake:{server:"cover.example",server_port:443}}]' "$SB_MAIN" > "$SB_WORK/shared-rebuild"
cp "$SB_WORK/shared-rebuild" "$SB_MAIN"
node_change ws new shadowtls tag still-ignored port 25563 host cover.example
assert_json "$SB_MAIN" '[.inbounds[].tag] as $tags | ($tags|length)==($tags|unique|length) and (.inbounds[1].detour!="ws-inner") and any(.inbounds[];.tag=="ws-inner") and all(.inbounds[]|select(.type=="shadowtls");.detour as $t|$tags|index($t)!=null)'
# 生成接口覆盖位置参数；值即使与字段同名也保持在原位置。
generate_case() {
    SB_GENERATE=1 node_add "$@" <<< matrix > "$SB_WORK/matrix"
    if [[ -n ${TEST_CORE:-} ]]; then "$TEST_CORE" check -c "$SB_WORK/matrix"; fi
}
generate_case socks 25564 path method
assert_json "$SB_WORK/matrix" '.inbounds[0].users[0]=={username:"path",password:"method"}'
generate_case ss 25565 auto auto
assert_json "$SB_WORK/matrix" '.inbounds[0].method=="2022-blake3-aes-128-gcm"'
generate_case direct 25566 target.example 8443
assert_json "$SB_WORK/matrix" '.inbounds[0].override_address=="target.example" and .inbounds[0].override_port==8443'
SB_AUTO_FRONTEND=1
generate_case ws 25567 auto /plain
assert_json "$SB_WORK/matrix" '.inbounds[0].listen=="::" and .inbounds[0].transport.path=="/plain" and (.inbounds[0]|has("tls")|not)'
generate_case vmess-http --fields tag plain-http port 25568 path /http
assert_json "$SB_WORK/matrix" '.inbounds[0].listen=="::" and (.inbounds[0]|has("tls")|not)'
generate_case wss front.example auto auto
assert_json "$SB_WORK/matrix" '.inbounds[0].listen=="127.0.0.1" and (.inbounds[0].transport.path|startswith("/")) and (.inbounds[0]|has("tls")|not)'
SB_AUTO_FRONTEND=0
generate_case vws front.example auto /vless
assert_json "$SB_WORK/matrix" '.inbounds[0].listen=="::" and .inbounds[0].tls.enabled and .inbounds[0].tls.certificate[0]=="-----BEGIN CERTIFICATE-----"'
generate_case anytls 25569 path acme.example
assert_json "$SB_WORK/matrix" '.inbounds[0].users[0].password=="path" and .inbounds[0].tls.certificate_provider.domain==["acme.example"]'
node_add anytls tag compatible-selfsigned port 25570 host self.example
uri=$(node_url compatible-selfsigned)
[[ $uri == *insecure=1* && $uri == *allowInsecure=1* ]]
if [[ -n ${TEST_CORE:-} ]]; then
    # 每个已支持名字及其 HTTP TLS 后缀都交给真实核心验证候选。
    presets=(reality r vless vless-reality rh2 vless-reality-h2 vmess tcp vmess-tcp ws vmess-ws http vmess-http quic vmess-quic wss h2 hu vmess-h2 vmess-httpupgrade vws vh2 vhu vless-ws vless-h2 vless-httpupgrade tws th2 thu trojan-ws trojan-h2 trojan-httpupgrade ss ss2022 shadowsocks socks direct tuic hy2 hysteria2 trojan trojan-tcp anytls shadowtls shadowtls-ss ss-shadowtls shadowtls3 shadowtls-v3 shadowtls2 shadowtls-v2)
    for preset in "${presets[@]}"; do
        if [[ $preset == direct ]]; then
            generate_case "$preset" --fields tag core-check port 25600 door-addr 192.0.2.80 door-port 80
        else generate_case "$preset" --fields tag core-check port 25600 host synthetic.example; fi
    done
    for preset in ws vmess-ws http vmess-http wss h2 hu vmess-h2 vmess-httpupgrade vws vh2 vhu vless-ws vless-h2 vless-httpupgrade tws th2 thu trojan-ws trojan-h2 trojan-httpupgrade; do
        generate_case "$preset-tls" --fields tag core-check port 25600 host synthetic.example
    done
    generate_case tuic 25601 auto auto
    generate_case hysteria2 25602 auto
    generate_case trojan 25603 auto
    generate_case vmess 25604 auto auto
    generate_case tcp 25605 auto auto
    generate_case http 25606 auto auto
    generate_case quic 25607 auto auto
    generate_case r auto auto synthetic.example
    generate_case rh2 auto auto synthetic.example
    generate_case anytls 25608 auto
fi
printf 'nodes tests passed\n'
