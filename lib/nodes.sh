#!/usr/bin/env bash
# 节点与 DNS 只构建候选文档；检查和生效由文档层负责。

_nodes_jq() {
    local -a flags=()
    case ${OSTYPE:-} in msys*|cygwin*) flags=(-b) ;; esac
    jq "${flags[@]}" "$@"
}

_node_json() {
    local out
    out=$(json_temp) || return
    _nodes_jq "$@" > "$out" || return
    printf '%s\n' "$out"
}

_node_load() {
    NODE_RECORD=$(documents_select "${1:-}") || return
    NODE_FILE=$(_nodes_jq -er '.file' <<< "$NODE_RECORD") || return
    NODE_INDEX=$(_nodes_jq -er '.index' <<< "$NODE_RECORD") || return
    NODE_DATA=$(json_temp) || return
    _nodes_jq '.value' <<< "$NODE_RECORD" > "$NODE_DATA"
}

_node_user() {
    local data=$1 count selection
    count=$(_nodes_jq '.users // [] | length' "$data") || return
    if (( count == 0 )); then printf 'null\n'; return; fi
    if (( count == 1 )); then printf '0\n'; return; fi
    local -a choices=()
    mapfile -t choices < <(_nodes_jq -r '.users | to_entries[] | "\(.key + 1): \(.value.name // .value.username // .value.uuid // "用户")"' "$data")
    selection=$(choose_index '选择用户' "${choices[@]}") || return
    [[ $selection =~ ^[0-9]+$ ]] && (( selection < count )) || { fail '用户选择无效'; return 1; }
    printf '%s\n' "$selection"
}

_node_port() {
    local value=$1
    if [[ $value == auto ]]; then free_port; return; fi
    [[ $value =~ ^[0-9]{1,5}$ ]] && (( 10#$value > 0 && 10#$value <= 65535 )) || { fail '端口必须为 1 到 65535 或 auto'; return 1; }
    printf '%s\n' "$((10#$value))"
}

_node_random() {
    local value
    value=$(openssl rand "$@") || return
    printf '%s\n' "${value//$'\r'/}"
}

_node_password() {
    case ${1:-} in
        2022-blake3-aes-128-gcm) _node_random -base64 16 ;;
        2022-*) _node_random -base64 32 ;;
        *) _node_random -hex 16 ;;
    esac
}

_node_private() {
    local tmp
    tmp=$(json_temp) || return
    openssl genpkey -algorithm X25519 -outform DER -out "$tmp" || return
    tail -c 32 "$tmp" | openssl base64 -A | tr '+/' '-_' | tr -d '='
    printf '\n'
}

_node_public() {
    local private=$1 raw der pub
    [[ $private =~ ^[A-Za-z0-9_-]{43}$ ]] || { fail 'Reality 私钥必须是 32 字节的 Base64URL'; return 1; }
    raw=$(json_temp) && der=$(json_temp) && pub=$(json_temp) || return
    printf '%s=' "$private" | tr '_-' '/+' | openssl base64 -d -A > "$raw" || return
    [[ $(wc -c < "$raw") -eq 32 ]] || { fail 'Reality 私钥长度错误'; return 1; }
    { printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x6e\x04\x22\x04\x20'; cat "$raw"; } > "$der"
    openssl pkey -inform DER -in "$der" -pubout -outform DER -out "$pub" || return
    tail -c 32 "$pub" | openssl base64 -A | tr '+/' '-_' | tr -d '='
    printf '\n'
}

_node_replace() {
    local file=$1 index=$2 data=$3 candidate
    candidate=$(_node_json --argjson i "$index" --slurpfile n "$data" '.inbounds[$i]=$n[0]' "$file") || return
    documents_commit "$file" "$candidate"
}

_node_type() {
    local type=$1
    forms_init || return
    local types
    types=$(forms_types Inbound) || return
    [[ $'\n'$types$'\n' == *$'\n'"$type"$'\n'* ]] || { fail "核心不支持入站类型：$type"; return 1; }
}

# 快捷参数为语义字段/值；数值首参数兼容端口，未知参数明确拒绝。
_node_selfsigned() {
    local data=$1 domain=$2 pem san validity_days=3650
    [[ $domain =~ ^[A-Za-z0-9.:-]+$ ]] || { fail '自签证书名称必须是域名或 IP 地址'; return 1; }
    san="DNS:$domain"
    if [[ $domain == *:* || $domain =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then san="IP:$domain"; fi
    # 私钥和证书直接进入候选 JSON，生成模式也不落地 TLS 文件。
    pem=$(MSYS_NO_PATHCONV=1 openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout - -out - \
        -subj "/CN=$domain" -addext "subjectAltName=$san" -days "$validity_days") || return
    _node_json --arg d "$domain" --arg pem "$pem" \
        '($pem | gsub("\r";"") | capture("(?<key>-----BEGIN PRIVATE KEY-----[\\s\\S]*?-----END PRIVATE KEY-----)[\\s\\S]*?(?<cert>-----BEGIN CERTIFICATE-----[\\s\\S]*?-----END CERTIFICATE-----)")) as $p |
         .tls={enabled:true,server_name:$d,key:($p.key|split("\n")),certificate:($p.cert|split("\n"))}' "$data"
}

# front 是预设元数据；普通 VMess 传输不会隐式变为公网 TLS 前端。
_node_preset_options() {
    local -n preset_options=$1
    local preset=${2,,} tls_suffix=0
    preset_options=([type]='' [transport]='' [reality]=0 [shadow]=0 [version]=3 [front]=0 [needs_tls]=0 [profile]='')
    if [[ $preset == *-tls ]]; then tls_suffix=1; preset=${preset%-tls}; fi
    case $preset in
        reality|r|vless|vless-reality) preset_options[type]=vless; preset_options[reality]=1; preset_options[profile]=reality ;;
        rh2|vless-reality-h2) preset_options[type]=vless; preset_options[reality]=1; preset_options[transport]=http; preset_options[profile]=reality ;;
        vmess|tcp|vmess-tcp) preset_options[type]=vmess; preset_options[profile]=vmess ;;
        ws|vmess-ws) preset_options[type]=vmess; preset_options[transport]=ws; preset_options[profile]=vmess ;;
        http|vmess-http) preset_options[type]=vmess; preset_options[transport]=http; preset_options[profile]=vmess ;;
        quic|vmess-quic) preset_options[type]=vmess; preset_options[transport]=quic; preset_options[needs_tls]=1; preset_options[profile]=vmess ;;
        wss|h2|hu|vmess-h2|vmess-httpupgrade|vws|vh2|vhu|vless-ws|vless-h2|vless-httpupgrade|tws|th2|thu|trojan-ws|trojan-h2|trojan-httpupgrade)
            case $preset in vws|vh2|vhu|vless-*) preset_options[type]=vless ;; tws|th2|thu|trojan-*) preset_options[type]=trojan ;; *) preset_options[type]=vmess ;; esac
            case $preset in wss|vws|tws|*-ws) preset_options[transport]=ws ;; h2|vh2|th2|*-h2) preset_options[transport]=http ;; *) preset_options[transport]=httpupgrade ;; esac
            preset_options[front]=1; preset_options[needs_tls]=1; preset_options[profile]=tls-http ;;
        ss|ss2022|shadowsocks) preset_options[type]=shadowsocks; preset_options[profile]=ss ;;
        socks|direct|tuic) preset_options[type]=$preset; preset_options[profile]=$preset; [[ $preset != tuic ]] || preset_options[needs_tls]=1 ;;
        hy2|hysteria2|trojan|trojan-tcp|anytls)
            case $preset in hy2) preset=hysteria2 ;; trojan-tcp) preset=trojan ;; esac
            preset_options[type]=$preset; preset_options[needs_tls]=1; preset_options[profile]=password ;;
        shadowtls|shadowtls-ss|ss-shadowtls|shadowtls3|shadowtls-v3|shadowtls2|shadowtls-v2)
            preset_options[type]=shadowtls; preset_options[shadow]=1; preset_options[profile]=password
            case $preset in shadowtls2|shadowtls-v2) preset_options[version]=2 ;; esac ;;
        *) fail "未知预设：$preset；请用 add inbound 选择完整核心类型"; return 1 ;;
    esac
    if (( tls_suffix )); then
        [[ ${preset_options[reality]} == 0 && ${preset_options[transport]} =~ ^(ws|http|httpupgrade)$ ]] || { fail 'TLS 前端预设需要 WS、HTTP 或 HTTPUpgrade 传输'; return 1; }
        preset_options[front]=1; preset_options[needs_tls]=1; preset_options[profile]=tls-http
    fi
}

# 参数模式只由首项决定；位置参数中的密码永不再次按字段名解析。
_node_parse() {
    local -n parsed=$1
    local profile=$2 mode=positional key value canonical i=0
    shift 2
    parsed+=([tag]='' [port]=auto [password]=auto [uuid]=auto [domain]='' [path]='/' [method]=auto [username]=user [inner_password]=auto [tls]=selfsigned [target_address]='' [target_port]='' [form]=0)
    if (( $# )); then
        case $1 in --fields) mode=fields; shift ;; --positional|--) shift ;;
            tag|port|passwd|password|pass|id|uuid|host|sni|path|method|username|inner-password|tls|door-addr|door-port|+form) mode=fields ;; esac
    fi
    local -a positions=()
    case $profile in
        reality) positions=(port uuid domain) ;; ss) positions=(port method password) ;; direct) positions=(port target_address target_port) ;;
        socks) positions=(port username password) ;; tls-http) positions=(domain auth path) ;; vmess) positions=(port uuid path) ;;
        tuic) positions=(port uuid password) ;; password) positions=(port password); [[ ${parsed[type]} != anytls ]] || positions+=(domain) ;;
    esac
    if [[ $mode == fields ]]; then
        while (( $# )); do
            key=$1; shift
            if [[ $key == +form ]]; then parsed[form]=1; continue; fi
            case $key in
                tag|port|path|method|username|tls) canonical=$key ;; passwd|password|pass) canonical=password ;; id|uuid) canonical=uuid ;;
                host|sni) canonical=domain ;; inner-password) canonical=inner_password ;; door-addr) canonical=target_address ;; door-port) canonical=target_port ;;
                *) fail "语义参数必须使用字段和值，不可混入位置参数：$key"; return 1 ;;
            esac
            if (( $# )); then value=$1; shift; else value=$(read_text "设置 $key") || return; fi
            parsed[$canonical]=$value
        done
    else
        (( $# <= ${#positions[@]} )) || { fail '位置参数过多；语义参数请使用 --fields'; return 1; }
        for value in "$@"; do
            key=${positions[i]}; i=$((i+1))
            if [[ $key == auth ]]; then
                case ${parsed[type]} in vmess|vless) key=uuid ;; *) key=password ;; esac
            fi
            parsed[$key]=$value
        done
        if [[ ${parsed[type]} == anytls && -n ${parsed[domain]} ]]; then parsed[tls]=acme; fi
    fi
    case ${parsed[tls]} in selfsigned|acme) ;; *) fail 'tls 只接受 selfsigned 或 acme'; return 1 ;; esac
}

_node_method() {
    case $1 in
        auto) printf '2022-blake3-aes-128-gcm\n' ;;
        2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305|none|aes-128-gcm|aes-192-gcm|aes-256-gcm|chacha20-ietf-poly1305|xchacha20-ietf-poly1305) printf '%s\n' "$1" ;;
        *) fail '不支持的 Shadowsocks 预设加密方法，请使用完整表单'; return 1 ;;
    esac
}

_node_default_handshake() {
    # 自动 SNI 使用支持 TLS 的公共站点；不探测或修改远端站点。
    printf 'www.microsoft.com\n'
}

_node_build() {
    local preset=${1:-}
    (( $# == 0 )) || shift
    NODE_FRONT_HOST='' NODE_FRONT_PORT='' NODE_BUILD_FRONT=0
    if [[ -z $preset ]]; then
        local selected; local -a presets=(vless-reality rh2 vmess-ws wss trojan-ws ss socks direct tuic hysteria2 anytls shadowtls inbound)
        selected=$(choose_index '选择预设或完整表单' "${presets[@]}") || return
        preset=${presets[selected]}
    fi
    if [[ $preset == inbound ]]; then
        local type=${1:-} form_tag def
        (( $# == 0 )) || shift
        [[ $# == 0 ]] || { fail '完整表单不接受快捷参数'; return 1; }
        if [[ -z $type ]]; then
            forms_init || return
            local -a types=(); local idx
            mapfile -t types < <(forms_types Inbound)
            idx=$(choose_index '选择入站类型' "${types[@]}") || return
            type=${types[idx]}
        fi
        _node_type "$type" || return
        form_tag=${_NODE_BUILD_TAG:-}
        [[ -n $form_tag ]] || form_tag=$(read_text '节点标签' "$type") || return
        [[ -n $form_tag ]] || { fail '节点标签不能为空'; return 1; }
        NODE_DOCUMENT=$(json_temp) || return
        _nodes_jq -n --arg t "$type" --arg tag "$form_tag" '{inbounds:[{type:$t,tag:$tag}]}' > "$NODE_DOCUMENT" || return
        def=$(forms_definition Config) || return
        forms_edit "$def" "$NODE_DOCUMENT"; return
    fi
    local -A options=()
    _node_preset_options options "$preset" || return
    _node_parse options "${options[profile]}" "$@" || return
    NODE_BUILD_FRONT=${options[front]}
    local type=${options[type]} transport=${options[transport]} reality=${options[reality]} shadow=${options[shadow]} version=${options[version]} needs_tls=${options[needs_tls]}
    local tag=${_NODE_BUILD_TAG:-${options[tag]}} port=${options[port]} credential=${options[password]} uuid=${options[uuid]} domain=${options[domain]} path=${options[path]}
    local method username=${options[username]} innerpass=${options[inner_password]} tls_mode=${options[tls]} target_address=${options[target_address]} target_port=${options[target_port]}
    _node_type "$type" || return
    [[ -n $tag ]] || tag=$(read_text '节点标签' "$preset") || return
    [[ -n $tag ]] || { fail '节点标签不能为空'; return 1; }
    port=$(_node_port "$port") || return
    method=$(_node_method "${options[method]}") || return
    [[ $uuid != auto ]] || uuid=$(new_id) || return
    [[ $credential != auto ]] || credential=$(_node_password "$method") || return
    [[ $innerpass != auto ]] || innerpass=$(_node_password "$method") || return
    [[ $path != auto ]] || path="/$(_node_random -hex 8)" || return
    if [[ $domain == auto ]]; then
        if (( reality || shadow )); then domain=$(_node_default_handshake); else domain=$(server_address) || return; fi
    fi
    if (( reality || shadow )); then
        [[ -n $domain ]] || domain=$(read_text '握手域名 / SNI' "$(_node_default_handshake)") || return
    elif [[ ( ${options[front]} == 1 && ${SB_AUTO_FRONTEND:-1} != 0 ) || ( $tls_mode == acme && $needs_tls == 1 ) ]]; then
        [[ -n $domain ]] || domain=$(read_text '公网域名') || return
        [[ -n $domain ]] || { fail '公网域名不能为空'; return 1; }
    fi
    if (( needs_tls )) && [[ -z $domain ]]; then domain=$(server_address) || return; fi
    local listen='::'
    if [[ ${options[front]} == 1 && ${SB_AUTO_FRONTEND:-1} != 0 ]]; then
        NODE_FRONT_HOST=$domain; NODE_FRONT_PORT=$port
        port=$(free_port) || return; listen=127.0.0.1; needs_tls=0
    fi
    NODE_BUILD=$(json_temp) || return
    _nodes_jq -n --arg t "$type" --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
        --arg pass "$credential" --arg uuid "$uuid" --arg method "$method" --arg username "$username" \
        '{type:$t,tag:$tag,listen:$listen,listen_port:$port} +
         (if $t=="shadowsocks" then {method:$method,password:$pass}
          elif $t=="socks" then {users:[{username:$username,password:$pass}]}
          elif $t=="vmess" or $t=="vless" then {users:[{uuid:$uuid}]}
          elif $t=="tuic" then {users:[{uuid:$uuid,password:$pass}]}
          elif $t=="direct" or $t=="shadowtls" then {} else {users:[{password:$pass}]} end)' > "$NODE_BUILD" || return
    if [[ $type == direct ]]; then
        [[ -n $target_address ]] || target_address=$(read_text '目标地址') || return
        [[ -n $target_port ]] || target_port=$(read_text '目标端口') || return
        [[ -n $target_address && $target_port != auto ]] || { fail 'Direct 需要目标地址和固定端口'; return 1; }
        target_port=$(_node_port "$target_port") || return
        NODE_BUILD=$(_node_json --arg a "$target_address" --argjson p "$target_port" '.override_address=$a|.override_port=$p' "$NODE_BUILD") || return
    fi
    if [[ -n $transport ]]; then
        NODE_BUILD=$(_node_json --arg t "$transport" --arg p "$path" '.transport={type:$t} + (if $t=="quic" then {} else {path:$p} end)' "$NODE_BUILD") || return
    fi
    if (( needs_tls )); then
        if [[ $tls_mode == acme ]]; then
            NODE_BUILD=$(_node_json --arg d "$domain" '.tls={enabled:true,server_name:$d,certificate_provider:{type:"acme",domain:[$d]}}' "$NODE_BUILD") || return
        else NODE_BUILD=$(_node_selfsigned "$NODE_BUILD" "$domain") || return; fi
    fi
    if (( reality )); then
        local private short
        private=$(_node_private) && short=$(_node_random -hex 8) || return
        NODE_BUILD=$(_node_json --arg d "$domain" --arg k "$private" --arg s "$short" \
            'if .transport==null then .users[0].flow="xtls-rprx-vision" else . end | .tls={enabled:true,server_name:$d,reality:{enabled:true,handshake:{server:$d,server_port:443},private_key:$k,short_id:[$s]}}' "$NODE_BUILD") || return
    fi
    NODE_DOCUMENT=$(_node_json '{inbounds:[.]}' "$NODE_BUILD") || return
    if (( shadow )); then
        _node_type shadowsocks || return
        NODE_DOCUMENT=$(_node_json --arg d "$domain" --arg p "$credential" --arg m "$method" --arg ip "$innerpass" --argjson v "$version" \
          '.inbounds[0] |= (. + {version:$v,handshake:{server:$d,server_port:443},detour:(.tag+"-inner")} +
          (if $v==3 then {users:[{password:$p}]} else {password:$p} end)) |
          .inbounds += [{type:"shadowsocks",tag:(.inbounds[0].tag+"-inner"),method:$m,password:$ip}]' "$NODE_DOCUMENT") || return
    fi
    if [[ ${options[form]} == 1 ]]; then
        local def
        def=$(forms_definition Config) || return
        forms_edit "$def" "$NODE_DOCUMENT" || return
    fi
}

node_add() {
    _node_build "$@" || return
    if [[ ${SB_GENERATE:-0} == 1 ]]; then cat "$NODE_DOCUMENT"; return; fi
    local tag target existing
    tag=$(_nodes_jq -er '.inbounds[0].tag | select(length>0)' "$NODE_DOCUMENT") || { fail '必须设置节点标签'; return 1; }
    existing=$(documents_inventory) || return
    _nodes_jq -e --slurpfile d "$NODE_DOCUMENT" '[.[].value.tag] as $tags | all($d[0].inbounds[]; .tag as $t | $tags|index($t)|not)' <<< "$existing" >/dev/null || { fail '节点标签已经存在'; return 1; }
    target="$SB_PARTS/node-$(new_id).json"
    local front_node
    if [[ -n $NODE_FRONT_HOST ]]; then
        front_node=$(_node_json '.inbounds[0]' "$NODE_DOCUMENT") || return
        frontend_create "$front_node" "$NODE_FRONT_HOST" "$NODE_FRONT_PORT" check || return
    fi
    documents_commit "$target" "$NODE_DOCUMENT" || return
    if [[ -n $NODE_FRONT_HOST ]]; then frontend_create "$front_node" "$NODE_FRONT_HOST" "$NODE_FRONT_PORT" apply || return; fi
}

_node_existing_preset() {
    local front=$2
    _nodes_jq -er --argjson front "$front" '
      .type as $type | (.transport.type // "tcp") as $transport |
      if $type=="shadowtls" then (if .version==2 then "shadowtls-v2" else "shadowtls" end)
      elif $type=="vless" and .tls.reality.enabled==true then (if $transport=="http" then "rh2" elif $transport=="tcp" then "reality" else error("Reality 预设不支持此传输，请使用完整表单") end)
      elif $type=="vmess" then
        if $transport=="http" and (.tls.enabled==true or $front!=null) then "h2"
        elif $transport=="ws" and (.tls.enabled==true or $front!=null) then "wss"
        elif $transport=="tcp" then "vmess" else "vmess-"+$transport end
      elif $type=="vless" or $type=="trojan" then
        if $transport=="tcp" then $type else $type+"-"+(if $transport=="http" then "h2" else $transport end) end
      else $type end' "$1"
}

_node_rebuild() {
    local old_file=$NODE_FILE old_index=$NODE_INDEX old_tag old_inner inventory occupied dedicated=false old_front candidate front_node new_inner
    old_tag=$(_nodes_jq -r '.tag // ""' "$NODE_DATA") || return
    old_inner=$(_nodes_jq -r 'if .type=="shadowtls" then .detour // "" else "" end' "$NODE_DATA") || return
    old_front=$(frontend_lookup "$NODE_DATA") || return
    inventory=$(documents_inventory) || return
    if [[ -n $old_inner ]]; then
        dedicated=$(_nodes_jq --arg t "$old_inner" '[.[]|select(.value.detour==$t)]|length==1' <<< "$inventory") || return
    fi
    occupied=$(_nodes_jq --arg f "$old_file" --argjson i "$old_index" --arg t "$old_inner" --argjson d "$dedicated" \
        '[.[]|select((.file==$f and (.index==$i or ($d and .value.tag==$t)))|not)|.value.tag // empty]' <<< "$inventory") || return
    local _NODE_BUILD_TAG=$old_tag SB_AUTO_FRONTEND=${SB_AUTO_FRONTEND:-1}
    [[ $old_front == null ]] || SB_AUTO_FRONTEND=0
    _node_build "$@" || return
    [[ $(_nodes_jq -r '.inbounds[0].tag' "$NODE_DOCUMENT") == "$old_tag" ]] || { fail '重建必须保留选中节点的标签'; return 1; }
    if [[ $old_front != null && $NODE_BUILD_FRONT == 1 ]]; then
        NODE_DOCUMENT=$(_node_json '.inbounds[0] |= (del(.tls) | .listen="127.0.0.1")' "$NODE_DOCUMENT") || return
    fi
    # 共享内层保留原样；新组合若撞名，给新的专属内层分配独立标签。
    if _nodes_jq -e '.inbounds|length==2 and .[0].type=="shadowtls" and .[0].detour==.[1].tag' "$NODE_DOCUMENT" >/dev/null; then
        new_inner=$(_nodes_jq -r '.inbounds[1].tag' "$NODE_DOCUMENT") || return
        if _nodes_jq -e --arg t "$new_inner" 'index($t)!=null' <<< "$occupied" >/dev/null; then
            new_inner="$old_tag-inner-$(new_id)" || return
            NODE_DOCUMENT=$(_node_json --arg t "$new_inner" '.inbounds[0].detour=$t | .inbounds[1].tag=$t' "$NODE_DOCUMENT") || return
        fi
    fi
    _nodes_jq -e --argjson occupied "$occupied" '[.inbounds[].tag // empty] as $tags | ($tags|length)==($tags|unique|length) and all($tags[]; . as $t | $occupied|index($t)|not)' "$NODE_DOCUMENT" >/dev/null || { fail '重建的关联节点标签与现有节点冲突'; return 1; }
    candidate=$(_node_json --argjson i "$old_index" --arg t "$old_inner" --argjson dedicated "$dedicated" --slurpfile n "$NODE_DOCUMENT" \
        '.inbounds = ([.inbounds|to_entries[] | if .key==$i then $n[0].inbounds[] else .value | select(($dedicated and .tag==$t)|not) end]) |
         if $n[0]|has("dns") then .dns = ((.dns // {}) * ($n[0].dns|del(.servers,.rules))) | .dns.servers=((.dns.servers // [])+($n[0].dns.servers // [])) | .dns.rules=((.dns.rules // [])+($n[0].dns.rules // [])) else . end' "$old_file") || return
    if [[ -n $NODE_FRONT_HOST ]]; then
        front_node=$(_node_json '.inbounds[0]' "$NODE_DOCUMENT") || return
        frontend_create "$front_node" "$NODE_FRONT_HOST" "$NODE_FRONT_PORT" check || return
    fi
    documents_commit "$old_file" "$candidate" || return
    if [[ -n $NODE_FRONT_HOST ]]; then frontend_create "$front_node" "$NODE_FRONT_HOST" "$NODE_FRONT_PORT" apply || return; fi
}

_node_change_method() {
    local data=$1 method old password candidate count i group
    method=$(_node_method "$2") || return
    old=$(_nodes_jq -r '.method' "$data") || return
    if [[ $method == "$old" ]]; then printf '%s\n' "$data"; return; fi
    if [[ $method != 2022-* ]] && _nodes_jq -e '((.users // [])|length)>0 or ((.destinations // [])|length)>0' "$data" >/dev/null; then
        fail '多用户或中继模式需要 2022 方法，请先用完整表单调整账户结构'; return 1
    fi
    password=$(_node_password "$method") || return
    candidate=$(_node_json --arg m "$method" --arg p "$password" '.method=$m | .password=$p' "$data") || return
    for group in users destinations; do
        count=$(_nodes_jq --arg g "$group" '.[$g] // [] | length' "$candidate") || return
        for ((i=0;i<count;i++)); do
            password=$(_node_password "$method") || return
            candidate=$(_node_json --arg g "$group" --argjson i "$i" --arg p "$password" '.[$g][$i].password=$p' "$candidate") || return
        done
    done
    printf '%s\n' "$candidate"
}

node_change() {
    local selector=${1:-}; (( $# == 0 )) || shift
    _node_load "$selector" || return
    local field=${1:-} value count path user front candidate def type
    (( $# == 0 )) || shift
    if [[ -z $field ]]; then
        local idx; local -a fields=(settings port path passwd id key sni method host web username door-addr door-port new full)
        idx=$(choose_index '选择修改内容' "${fields[@]}") || return
        field=${fields[idx]}
    fi
    case $field in
        full)
            if (( $# )); then
                local preset current_front
                current_front=$(frontend_lookup "$NODE_DATA") || return
                preset=$(_node_existing_preset "$NODE_DATA" "$current_front") || return
                _node_rebuild "$preset" "$@"; return
            fi
            type=$(_nodes_jq -r '.type' "$NODE_DATA") || return
            def=$(forms_definition Inbound "$type") || return
            forms_edit "$def" "$NODE_DATA" || return
            _node_replace "$NODE_FILE" "$NODE_INDEX" "$NODE_DATA"; return ;;
        settings)
            type=$(_nodes_jq -r '.type' "$NODE_DATA") || return
            def=$(forms_definition Inbound "$type") || return
            if (( $# )); then
                [[ $# == 2 ]] || { fail 'settings 需要字段路径和值'; return 1; }
                forms_set "$def" "$NODE_DATA" "$1" "$2" || return
            else forms_edit "$def" "$NODE_DATA" || return; fi
            _node_replace "$NODE_FILE" "$NODE_INDEX" "$NODE_DATA"; return ;;
        new) _node_rebuild "$@"; return ;;
    esac
    if [[ $field == key ]]; then [[ $# -le 2 ]] || { fail 'key 仅接受私钥及可选校验公钥'; return 1; }
    else [[ $# -le 1 ]] || { fail '快捷字段只接受一个值'; return 1; }; fi
    if (( $# )); then value=$1; else value=$(read_text "设置 $field") || return; fi
    type=$(_nodes_jq -r '.type' "$NODE_DATA") || return
    front=$(frontend_lookup "$NODE_DATA") || return
    case $field in
        host|web) frontend_edit "$NODE_DATA" "$field" "$value"; return ;;
        port)
            value=$(_node_port "$value") || return
            if [[ $front != null ]]; then frontend_edit "$NODE_DATA" port "$value"; return; fi
            path='["listen_port"]' ;;
        path)
            _nodes_jq -e '.transport.type | IN("ws","http","httpupgrade")' "$NODE_DATA" >/dev/null || { fail '当前节点没有可修改路径的传输'; return 1; }
            [[ $value != auto ]] || value="/$(_node_random -hex 8)"
            path='["transport","path"]' ;;
        passwd|password|pass|id|uuid|username)
            user=$(_node_user "$NODE_DATA") || return
            case $field in id|uuid) field=uuid ;; passwd|pass) field=password ;; esac
            case $field:$type in
                uuid:vmess|uuid:vless|uuid:tuic|username:socks|password:socks|password:shadowsocks|password:trojan|password:anytls|password:hysteria2|password:tuic|password:shadowtls) ;;
                *) fail '当前协议不使用此用户字段，请使用 settings'; return 1 ;;
            esac
            if [[ $user != null ]]; then path="[\"users\",$user,\"$field\"]"; else
                [[ $field == password && ( $type == shadowsocks || $type == shadowtls ) ]] || { fail '当前节点没有此用户字段'; return 1; }
                path='["password"]'
            fi
            if [[ $value == auto ]]; then
                case $field in uuid) value=$(new_id) ;; username) value="user-$(_node_random -hex 4)" ;; password) value=$(_node_password "$(_nodes_jq -r '.method // ""' "$NODE_DATA")") ;; esac
            fi ;;
        key)
            _nodes_jq -e '.tls.reality.enabled == true' "$NODE_DATA" >/dev/null || { fail 'key 快捷操作仅用于 Reality 私钥，其他 TLS 密钥请用 settings'; return 1; }
            [[ $value != auto ]] || value=$(_node_private) || return
            local public
            public=$(_node_public "$value") || return
            if [[ $# == 2 && $public != "$2" ]]; then fail '公钥与实际私钥推导结果不一致'; return 1; fi
            candidate=$(_node_json --arg v "$value" '.tls.reality.private_key=$v | del(.tls.reality.public_key)' "$NODE_DATA") || return
            _node_replace "$NODE_FILE" "$NODE_INDEX" "$candidate"; return ;;
        sni)
            if [[ $type == shadowtls ]] || _nodes_jq -e '.tls.reality.enabled==true' "$NODE_DATA" >/dev/null; then
                [[ $value != auto ]] || value=$(_node_default_handshake)
                if [[ $type == shadowtls ]]; then path='["handshake","server"]'; else
                    candidate=$(_node_json --arg v "$value" '.tls.server_name=$v | .tls.reality.handshake.server=$v' "$NODE_DATA") || return
                    _node_replace "$NODE_FILE" "$NODE_INDEX" "$candidate"; return
                fi
            else
                if [[ $value == auto ]]; then
                    value=$(_node_tls_domain "$NODE_DATA") || return
                    [[ -n $value ]] || value=$(server_address) || return
                fi
                path='["tls","server_name"]'
            fi ;;
        method)
            if [[ $type == shadowtls ]]; then
                local inner_tag
                inner_tag=$(_nodes_jq -r '.detour // ""' "$NODE_DATA") || return
                [[ -n $inner_tag ]] || { fail 'ShadowTLS 没有内层'; return 1; }
                node_change "$inner_tag" method "$value"; return
            fi
            [[ $type == shadowsocks ]] || { fail 'method 仅用于 Shadowsocks'; return 1; }
            candidate=$(_node_change_method "$NODE_DATA" "$value") || return
            _node_replace "$NODE_FILE" "$NODE_INDEX" "$candidate"; return ;;
        door-addr|door-port)
            [[ $type == direct ]] || { fail 'door 字段仅用于 Direct'; return 1; }
            if [[ $field == door-addr ]]; then path='["override_address"]'; else value=$(_node_port "$value") || return; path='["override_port"]'; fi ;;
        *) fail "未知节点字段：$field"; return 1 ;;
    esac
    case $field in port|door-port) candidate=$(_node_json --argjson p "$path" --argjson v "$value" 'setpath($p;$v)' "$NODE_DATA") ;;
        *) candidate=$(_node_json --argjson p "$path" --arg v "$value" 'setpath($p;$v)' "$NODE_DATA") ;; esac
    [[ -n $candidate ]] || return 1
    _node_replace "$NODE_FILE" "$NODE_INDEX" "$candidate"
}

node_delete() {
    _node_load "${1:-}" || return
    local inner inventory candidate
    inner=$(_nodes_jq -r 'if .type=="shadowtls" then .detour // "" else "" end' "$NODE_DATA") || return
    inventory=$(documents_inventory) || return
    # 专属内层只在同文档删除；跨文档与共享引用交给核心拒绝残留。
    local dedicated=false
    if [[ -n $inner ]]; then
        dedicated=$(_nodes_jq --arg t "$inner" --arg f "$NODE_FILE" '[.[]|select(.value.detour==$t)]|length==1' <<< "$inventory") || return
    fi
    candidate=$(_node_json --argjson i "$NODE_INDEX" --arg t "$inner" --argjson dedicated "$dedicated" \
        '.inbounds |= (to_entries | map(select(.key!=$i) | .value | select(($dedicated and .tag==$t)|not)))' "$NODE_FILE") || return
    documents_commit "$NODE_FILE" "$candidate"
}

_node_tls_domain() {
    local data=$1 provider domain file found='[]' matches
    domain=$(_nodes_jq -r '.tls | if (.certificate_provider|type)=="object" then .certificate_provider.domain[0] // empty else empty end' "$data") || return
    if [[ -n $domain ]]; then printf '%s\n' "$domain"; return; fi
    provider=$(_nodes_jq -r '.tls.certificate_provider | select(type=="string")' "$data") || return
    [[ -n $provider ]] || return 0
    while IFS= read -r -d '' file; do
        matches=$(_nodes_jq --arg t "$provider" '[.certificate_providers // [] | .[] | select(.tag==$t)]' "$file") || return
        found=$(_nodes_jq -n --argjson a "$found" --argjson b "$matches" '$a+$b') || return
    done < <(documents_list)
    [[ $(_nodes_jq length <<< "$found") == 1 ]] || { fail '证书提供者缺失或重复'; return 1; }
    _nodes_jq -r '.[0].domain[0] // empty' <<< "$found"
}

_node_certificate_view() {
    local data=$1 cert source subject issuer pin
    cert=$(json_temp) || return
    _nodes_jq -r '.tls.certificate // [] | if type=="array" then join("\n") else . end' "$data" > "$cert" || return
    if [[ ! -s $cert || $(wc -c < "$cert") -le 1 ]]; then
        source=$(_nodes_jq -r '.tls.certificate_path // empty' "$data") || return
        if [[ -z $source ]]; then printf '{}\n'; return; fi
        [[ $source == /* ]] || source="$SB_ROOT/$source"
        cp -- "$source" "$cert" || return
    fi
    subject=$(openssl x509 -in "$cert" -noout -subject) || return
    issuer=$(openssl x509 -in "$cert" -noout -issuer) || return
    if [[ ${subject#*=} == "${issuer#*=}" ]] && openssl verify -CAfile "$cert" "$cert" >/dev/null 2>&1; then
        pin=$(openssl x509 -in "$cert" -noout -sha256 -fingerprint) || return
        pin=${pin#*=}; pin=${pin//:/}; pin=${pin//$'\r'/}
        _nodes_jq -n --arg p "$pin" '{selfsigned:true,cert_pin:$p}'
    else printf '{}\n'; fi
}

_node_view() {
    _node_load "${1:-}" || return
    local user front host port public='' inner=null inner_user=null inventory matches innerfile
    if [[ ${2:-url} == info ]]; then user=null; else user=$(_node_user "$NODE_DATA") || return; fi
    front=$(frontend_lookup "$NODE_DATA") || return
    host=$(_nodes_jq -r '.host // empty' <<< "$front") || return
    [[ -n $host ]] || host=$(server_address) || return
    port=$(_nodes_jq -r '.port // empty' <<< "$front") || return
    [[ -n $port ]] || port=$(_nodes_jq -r '.listen_port // empty' "$NODE_DATA") || return
    if _nodes_jq -e '.tls.reality.enabled==true' "$NODE_DATA" >/dev/null; then
        public=$(_node_public "$(_nodes_jq -r '.tls.reality.private_key' "$NODE_DATA")") || return
    fi
    if _nodes_jq -e '.type=="shadowtls"' "$NODE_DATA" >/dev/null; then
        inventory=$(documents_inventory) || return
        matches=$(_nodes_jq --arg t "$(_nodes_jq -r '.detour // ""' "$NODE_DATA")" '[.[]|select(.value.tag==$t)]' <<< "$inventory") || return
        [[ $(_nodes_jq 'length' <<< "$matches") == 1 ]] || { fail 'ShadowTLS 内层缺失或存在歧义'; return 1; }
        inner=$(_nodes_jq '.[0].value' <<< "$matches") || return
        if [[ ${2:-url} != info && $(_nodes_jq -r '.type' <<< "$inner") != shadowsocks ]]; then fail '仅 Shadowsocks 内层具有组合分享格式'; return 1; fi
        innerfile=$(json_temp) || return
        printf '%s\n' "$inner" > "$innerfile"
        local iu
        if [[ ${2:-url} == info ]]; then iu=null; else iu=$(_node_user "$innerfile") || return; fi
        inner_user=$(_nodes_jq --argjson u "$iu" 'if $u==null then null else .users[$u] end' "$innerfile") || return
    fi
    local tls_domain cert_view='{}'
    tls_domain=$(_node_tls_domain "$NODE_DATA") || return
    if [[ $front == null ]]; then cert_view=$(_node_certificate_view "$NODE_DATA") || return; fi
    _nodes_jq -n --slurpfile n "$NODE_DATA" --argjson u "$user" --argjson f "$front" --arg h "$host" --arg p "$port" --arg k "$public" --argjson inner "$inner" --argjson iu "$inner_user" --arg domain "$tls_domain" --argjson cert "$cert_view" \
        '{inbound:$n[0],user:(if $u==null then null else $n[0].users[$u] end),front:$f,host:$h,port:(if $p=="" then null else $p|tonumber end),public_key:$k,inner:$inner,inner_user:$iu,tls_domain:(if $domain=="" then null else $domain end)} + $cert'
}

node_url() {
    local view
    view=$(_node_view "${1:-}") || return
    _nodes_jq -er -f "$SB_PROJECT/lib/links.jq" <<< "$view"
}

_node_show() {
    local data
    data=$(_node_json 'walk(if type=="object" then with_entries(if (.key|test("private_key|^key$|^key_path$")) then .value="[隐藏]" else . end) else . end)' "$1") || return
    forms_show "$data"
}

node_info() {
    if [[ ${2:-} == settings ]]; then
        _node_load "${1:-}" || return
        _node_show "$NODE_DATA"; return
    fi
    local view data
    view=$(_node_view "${1:-}" info) || return
    data=$(json_temp) || return
    printf '%s\n' "$view" > "$data"
    _node_show "$data"
}

node_qr() {
    local uri
    uri=$(node_url "${1:-}") || return
    qrencode -t ANSIUTF8 -- "$uri"
}

_dns_inventory() {
    local file item result='[]'
    while IFS= read -r -d '' file; do
        item=$(_nodes_jq --arg f "$file" '[.dns.servers // [] | to_entries[] | {file:$f,index:.key,value:.value}]' "$file") || return
        result=$(_nodes_jq -n --argjson a "$result" --argjson b "$item" '$a+$b') || return
    done < <(documents_list)
    printf '%s\n' "$result"
}

_dns_select() {
    local tag=${1:-} items count index
    items=$(_dns_inventory) || return
    if [[ -n $tag ]]; then items=$(_nodes_jq --arg t "$tag" '[.[]|select(.value.tag==$t)]' <<< "$items") || return; fi
    count=$(_nodes_jq 'length' <<< "$items") || return
    (( count > 0 )) || { fail '没有匹配的 DNS 服务器'; return 1; }
    if (( count == 1 )); then _nodes_jq '.[0]' <<< "$items"; return; fi
    local -a choices=()
    mapfile -t choices < <(_nodes_jq -r '.[] | "\(.value.tag // .value.type // "DNS") [\(.file)]"' <<< "$items")
    index=$(choose_index '选择 DNS 服务器' "${choices[@]}") || return
    _nodes_jq --argjson i "$index" '.[$i]' <<< "$items"
}

_dns_address() {
    local address=$1 type=udp endpoint host port='' path=''
    [[ -n $address && $address != *[[:space:]@\#]* ]] || { fail 'DNS 地址不能为空，也不能含空白、认证信息或片段'; return 1; }
    if [[ $address == local ]]; then printf '{"type":"local"}\n'; return; fi
    if [[ $address == *://* ]]; then type=${address%%://*}; endpoint=${address#*://}; else endpoint=$address; fi
    case $type in udp|tcp) port=53 ;; tls) port=853 ;; https) port=443 ;; *) fail 'DNS 地址支持 local、UDP、TCP、TLS 或 HTTPS'; return 1 ;; esac
    if [[ $endpoint == */* ]]; then
        path=/${endpoint#*/}; endpoint=${endpoint%%/*}
        [[ $type == https ]] || { fail '只有 HTTPS DNS 地址可以包含路径'; return 1; }
    fi
    [[ $endpoint != *\?* ]] || { fail 'DNS 端点不能包含查询参数'; return 1; }
    local explicit_port=''
    if [[ $endpoint =~ ^\[([^]]+)\](:([0-9]+))?$ ]]; then
        host=${BASH_REMATCH[1]}; explicit_port=${BASH_REMATCH[3]:-}
    elif [[ $endpoint == *:*:* ]]; then host=$endpoint
    elif [[ $endpoint == *:* ]]; then host=${endpoint%:*}; explicit_port=${endpoint##*:}; [[ -n $explicit_port ]] || { fail 'DNS 端口不能为空'; return 1; }
    else host=$endpoint; fi
    [[ -z $explicit_port ]] || port=$(_node_port "$explicit_port") || return
    if [[ $host == *:* ]]; then
        _nodes_jq -en --arg h "$host" '$h | test("^[0-9A-Fa-f:]+$") and (split("::")|length)<=2 and ([split(":")[]|select(length>0)]|all(.[];length<=4)) and (if contains("::") then ([split(":")[]|select(length>0)]|length)<8 else (split(":")|length)==8 end)' >/dev/null || { fail 'DNS IPv6 地址无效'; return 1; }
    elif [[ $host =~ ^[0-9.]+$ ]]; then
        _nodes_jq -en --arg h "$host" '$h|split(".")|length==4 and all(.[];test("^[0-9]{1,3}$") and (tonumber<=255))' >/dev/null || { fail 'DNS IPv4 地址无效'; return 1; }
    else
        _nodes_jq -en --arg h "$host" '$h|length>0 and length<=253 and (split(".")|all(.[];test("^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")))' >/dev/null || { fail 'DNS 域名格式无效'; return 1; }
    fi
    [[ $type != https || -n $path ]] || path=/dns-query
    _nodes_jq -n --arg t "$type" --arg h "$host" --argjson p "$port" --arg path "$path" \
        '{type:$t,server:$h,server_port:$p} + (if $t=="https" then {path:$path} else {} end)'
}

_dns_unused_tag() {
    local inventory=$1 prefix=$2 tag=$2 suffix=1
    while _nodes_jq -e --arg t "$tag" 'any(.[];.value.tag==$t)' <<< "$inventory" >/dev/null; do
        suffix=$((suffix+1)); tag="$prefix-$suffix"
    done
    printf '%s\n' "$tag"
}

_dns_set() {
    local server inventory additions='[]' bootstrap='' tag candidate host
    server=$(_dns_address "$1") || return
    inventory=$(_dns_inventory) || return
    host=$(_nodes_jq -r '.server // empty' <<< "$server") || return
    if [[ -n $host && $host != *:* && ! $host =~ ^[0-9.]+$ ]]; then
        bootstrap=$(_nodes_jq -r '[.[]|select(.value.type=="local" and (.value.tag // "")!="")][0].value.tag // empty' <<< "$inventory") || return
        if [[ -z $bootstrap ]]; then
            bootstrap=$(_dns_unused_tag "$inventory" manager-dns-bootstrap) || return
            additions=$(_nodes_jq -n --arg t "$bootstrap" '[{type:"local",tag:$t}]') || return
        fi
        server=$(_nodes_jq --arg t "$bootstrap" '.domain_resolver=$t' <<< "$server") || return
    fi
    tag=$(_nodes_jq -r --argjson server "$server" '[.[]|select((.value|del(.tag))==$server)][0].value.tag // empty' <<< "$inventory") || return
    if [[ -z $tag ]]; then
        tag=$(_dns_unused_tag "$inventory" manager-dns) || return
        additions=$(_nodes_jq --argjson s "$server" --arg t "$tag" '.+[$s+{tag:$t}]' <<< "$additions") || return
    fi
    candidate=$(_node_json --argjson additions "$additions" --arg t "$tag" '.dns.servers=((.dns.servers // [])+$additions) | .dns.final=$t' "$SB_MAIN") || return
    documents_commit "$SB_MAIN" "$candidate"
}

dns_command() {
    local op=${1:-} record file index data def candidate type tag value
    (( $# == 0 )) || shift
    if [[ -z $op ]]; then
        local idx; local -a ops=(info add change del settings set none)
        idx=$(choose_index 'DNS 管理' "${ops[@]}") || return
        op=${ops[idx]}
    fi
    case $op in
        set)
            [[ $# -le 1 ]] || { fail 'dns set 只接受一个语义地址'; return 1; }
            if (( $# )); then value=$1; else value=$(read_text 'DNS 地址（local、IP 或协议地址）') || return; fi
            _dns_set "$value" ;;
        none)
            [[ $# == 0 ]] || { fail 'dns none 不接受附加参数'; return 1; }
            # 只取消显式默认解析器，不删除可能被规则或其他配置引用的服务器。
            candidate=$(_node_json 'del(.dns.final)' "$SB_MAIN") || return
            documents_commit "$SB_MAIN" "$candidate" ;;
        settings)
            data=$(_node_json '.dns // {}' "$SB_MAIN") || return
            def=$(forms_definition DNS) || return
            if (( $# )); then [[ $# == 2 ]] || { fail 'DNS settings 需要字段和值'; return 1; }; forms_set "$def" "$data" "$1" "$2" || return
            else forms_edit "$def" "$data" || return; fi
            candidate=$(_node_json --slurpfile d "$data" '.dns=$d[0]' "$SB_MAIN") || return
            documents_commit "$SB_MAIN" "$candidate" ;;
        add)
            type=${1:-}
            if [[ -z $type ]]; then
                forms_init || return
                local -a types=(); local idx
                mapfile -t types < <(forms_types DNSServer)
                idx=$(choose_index '选择 DNS 类型' "${types[@]}") || return
                type=${types[idx]}
            fi
            data=$(json_temp) || return
            _nodes_jq -n --arg t "$type" '{type:$t}' > "$data"
            def=$(forms_definition DNSServer "$type") || return
            forms_edit "$def" "$data" || return
            tag=$(_nodes_jq -r '.tag // ""' "$data") || return
            local inventory
            inventory=$(_dns_inventory) || return
            [[ -n $tag ]] && _nodes_jq -e --arg t "$tag" 'all(.[];.value.tag!=$t)' <<< "$inventory" >/dev/null || { fail 'DNS tag 不能为空或重复'; return 1; }
            candidate=$(_node_json --slurpfile d "$data" '.dns.servers = ((.dns.servers // [])+[$d[0]])' "$SB_MAIN") || return
            documents_commit "$SB_MAIN" "$candidate" ;;
        change|del|info)
            record=$(_dns_select "${1:-}") || return
            (( $# == 0 )) || shift
            file=$(_nodes_jq -r '.file' <<< "$record"); index=$(_nodes_jq -r '.index' <<< "$record")
            data=$(json_temp) || return
            _nodes_jq '.value' <<< "$record" > "$data"
            if [[ $op == info ]]; then forms_show "$data"; return; fi
            if [[ $op == change ]]; then
                type=$(_nodes_jq -r '.type // ""' "$data")
                def=$(forms_definition DNSServer "$type") || return
                if (( $# )); then [[ $# == 2 ]] || { fail 'DNS change 需要字段和值'; return 1; }; forms_set "$def" "$data" "$1" "$2" || return
                else forms_edit "$def" "$data" || return; fi
                candidate=$(_node_json --argjson i "$index" --slurpfile d "$data" '.dns.servers[$i]=$d[0]' "$file") || return
            else candidate=$(_node_json --argjson i "$index" 'del(.dns.servers[$i])' "$file") || return; fi
            documents_commit "$file" "$candidate" ;;
        *) fail "未知 DNS 操作：$op"; return 1 ;;
    esac
}
