#!/usr/bin/env bash
# 官方接口资料：https://sing-box.sagernet.org/configuration/ 、https://caddyserver.com/docs/command-line
# 导入格式资料：https://xtls.github.io/config/inbound.html

host_check() {
    local binary=${1:-$SB_CORE}
    local -a args=(check -c "$SB_MAIN")
    [[ ! -d $SB_PARTS ]] || args+=(-C "$SB_PARTS")
    (cd -- "$SB_ROOT" && "$binary" "${args[@]}")
}

host_fix_frontend() {
    "$SB_CADDY" adapt --config "$SB_CADDYFILE" --adapter caddyfile --validate >/dev/null
}

host_service() {
    local action=${1:-status} component=${2:-sing-box}
    case $action in start|stop|restart|status|enable|disable) ;; *) fail '未知服务操作'; return 1;; esac
    case $component in sing-box|caddy) ;; *) fail '未知服务'; return 1;; esac
    case $action in
        start|restart)
            if [[ $component == sing-box ]]; then host_check || return; else host_fix_frontend || return; fi;;
    esac
    case ${SB_SERVICE_MANAGER:-none} in
        none) return 0;;
        systemd) systemctl "$action" "$component";;
        openrc)
            case $action in
                enable) rc-update add "$component" default;;
                disable) rc-update del "$component" default;;
                *) rc-service "$component" "$action";;
            esac;;
        *) fail '无法识别服务管理器'; return 1;;
    esac
}

host_log() {
    local arg=${1:-} merged candidate output
    case $arg in
        debug|info|warn|error)
            candidate=$(json_temp) || return
            jq --arg level "$arg" '.log.level = $level' "$SB_MAIN" >"$candidate" || return
            documents_commit "$SB_MAIN" "$candidate"; return;;
        ''|--no-follow|del) ;;
        *) fail '日志参数应为 debug/info/warn/error/del/--no-follow'; return 1;;
    esac
    merged=$(json_temp) || return
    documents_merge "$merged" || return
    output=$(jq -r '.log.output // empty' "$merged") || return
    if [[ -n $output ]]; then
        [[ $output == /* ]] || output="$SB_ROOT/$output"
        if [[ $arg == del ]]; then
            [[ ! -e $output ]] || truncate -s 0 -- "$output"
        elif [[ $arg == --no-follow ]]; then tail -n 100 -- "$output"
        else tail -n 100 -F -- "$output"; fi
    elif [[ $arg == del ]]; then
        fail '当前使用系统日志，没有可清空的日志文件'; return 1
    elif [[ ${SB_SERVICE_MANAGER:-none} == systemd ]]; then
        local -a args=(-u sing-box -n 100 --no-pager)
        [[ $arg == --no-follow ]] || args+=(-f)
        journalctl "${args[@]}"
    else
        fail '未配置文件日志，当前环境无 journal'; return 1
    fi
}

_host_download() {
    local url=$1 output=$2
    local -a args=(--fail --location --silent --show-error --proto '=https' --proto-redir '=https')
    [[ -z ${SB_DOWNLOAD_PROXY:-} ]] || args+=(--proxy "$SB_DOWNLOAD_PROXY")
    curl "${args[@]}" --output "$output" "$url"
}

# 下载并检查候选，不覆盖现有进程正在使用的可执行文件。
_host_release() {
    local component=$1 version=${2:-} output=$3 repo arch metadata tag asset url checksum archive unpack member
    case $component in core) repo=SagerNet/sing-box;; caddy) repo=caddyserver/caddy;; *) return 1;; esac
    case $(uname -m) in x86_64|amd64) arch=amd64;; aarch64|arm64) arch=arm64;; armv7l) arch=armv7;; *) fail '不支持的 CPU 架构'; return 1;; esac
    [[ $(uname -s) == Linux ]] || { fail '官方二进制安装仅支持 Linux'; return 1; }
    [[ -z $version || $version =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || { fail '版本格式无效'; return 1; }
    metadata=$(json_temp) || return
    if [[ -z $version ]]; then url="https://api.github.com/repos/$repo/releases/latest"
    else url="https://api.github.com/repos/$repo/releases/tags/v${version#v}"; fi
    _host_download "$url" "$metadata" || return
    tag=$(jq -er '.tag_name | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+([.-][A-Za-z0-9.-]+)?$"))' "$metadata") || return
    if [[ $component == core ]]; then asset="sing-box-${tag#v}-linux-$arch.tar.gz"
    else
        [[ $arch != armv7 ]] || arch=armv7
        asset="caddy_${tag#v}_linux_${arch}.tar.gz"
    fi
    url=$(jq -er --arg asset "$asset" '.assets[] | select(.name == $asset) | .browser_download_url' "$metadata") || return
    [[ $url == "https://github.com/$repo/releases/download/$tag/$asset" ]] || { fail '发行包地址不属于官方仓库'; return 1; }
    archive=$(json_temp) || return
    _host_download "$url" "$archive" || return
    # GitHub 若提供资产摘要，必须核对；旧发行包仍由 HTTPS 官方地址提供。
    checksum=$(jq -r --arg asset "$asset" '.assets[] | select(.name == $asset) | .digest // empty' "$metadata") || return
    if [[ -n $checksum ]]; then
        [[ $checksum == sha256:* ]] || { fail '不支持的发行摘要'; return 1; }
        [[ $(sha256sum "$archive" | cut -d ' ' -f 1) == "${checksum#sha256:}" ]] || { fail '发行包校验失败'; return 1; }
    fi
    unpack=$(mktemp -d "$SB_WORK/release.XXXXXX") || return
    if [[ $component == core ]]; then member="sing-box-${tag#v}-linux-$arch/sing-box"; else member=caddy; fi
    tar -xzf "$archive" -O "$member" >"$unpack/binary" || return
    chmod 755 "$unpack/binary" || return
    "$unpack/binary" version >/dev/null || return
    cp "$unpack/binary" "$output"
}

host_update() {
    local component=${1:-} value=${2:-} candidate target directory
    case $component in
        sh)
            directory=${value:-$SB_PROJECT}
            [[ -f $directory/install.sh ]] || { fail '需要本项目的本地源码目录'; return 1; }
            bash "$directory/install.sh" --adopt; return;;
        core) target=$SB_CORE;;
        caddy) target=$SB_CADDY;;
        *) fail '更新目标应为 core/caddy/sh'; return 1;;
    esac
    candidate=$(json_temp) || return
    _host_release "$component" "$value" "$candidate" || return
    chmod 755 "$candidate" || return
    if [[ $component == core ]]; then host_check "$candidate" || return
    else "$candidate" adapt --config "$SB_CADDYFILE" --adapter caddyfile --validate >/dev/null || return; fi
    mkdir -p "$(dirname "$target")" || return
    local staged
    staged=$(mktemp "${target}.new.XXXXXX") || return
    if ! install -m 755 "$candidate" "$staged" || ! mv -f -- "$staged" "$target"; then rm -f -- "$staged"; return 1; fi
    [[ $component != core ]] || component=sing-box
    host_service restart "$component"
}

host_install() { bash "$SB_PROJECT/install.sh" "$@"; }

_host_confirm() {
    local answer
    answer=$(read_text "$1 输入 YES 确认") || return
    [[ $answer == YES ]] || { fail '已取消'; return 1; }
}

host_reinstall() {
    local source_copy
    source_copy=$(mktemp -d "$SB_WORK/source.XXXXXX") || return
    _host_copy_source "$SB_PROJECT" "$source_copy" || return
    bash "$source_copy/install.sh" --reinstall "$@"
}

# 固定清单只包含本项目新作，绝不递归复制运行目录或外部脚本。
_host_copy_source() {
    local source=$1 destination=$2 item
    local -a artifacts=(sb install.sh VERSION README.md LICENSE SOURCES.md REQUIREMENTS.md CONTRACTS.md lib/common.sh lib/documents.sh lib/frontend.sh lib/forms.sh lib/schema.jq lib/nodes.sh lib/links.jq lib/host.sh lib/cli.sh)
    for item in "${artifacts[@]}"; do
        [[ -f $source/$item && ! -L $source/$item ]] || { fail "缺少独立源码文件：$item"; return 1; }
    done
    mkdir -p "$destination/lib" || return
    for item in "${artifacts[@]}"; do cp -- "$source/$item" "$destination/$item" || return; done
    chmod 755 "$destination/sb" "$destination/install.sh"
}

host_uninstall() {
    _host_confirm '卸载仅删除本管理器与指向它的命令链接，保留运行配置及核心。' || return
    local bin=${SB_BIN_DIR:-/usr/local/bin} link
    [[ -f $SB_ROOT/manager/.independent-manager ]] || { fail '缺少本管理器的安装标记'; return 1; }
    for link in sb sing-box; do
        if [[ -L $bin/$link && $(readlink "$bin/$link") == "$SB_ROOT/manager/sb" ]]; then rm -- "$bin/$link" || return; fi
    done
    rm -rf -- "$SB_ROOT/manager"
}

host_fix_base() {
    local candidate
    candidate=$(json_temp) || return
    jq 'if has("log") then . else .log={level:"info"} end |
        if has("dns") then . else .dns={servers:[]} end |
        if has("outbounds") then . else .outbounds=[{type:"direct",tag:"direct"}] end' "$SB_MAIN" >"$candidate" || return
    documents_commit "$SB_MAIN" "$candidate"
}

host_fix() {
    local selected file
    if [[ -n ${1:-} ]]; then
        selected=$(documents_select "$1") || return
        file=$(jq -er '.file' <<<"$selected") || return
        documents_check "$file" "$file" || return
        frontend_reconcile "$file" "$file" check || return
        frontend_reconcile "$file" "$file" apply
    else
        host_check || return
        [[ ! -f $SB_CADDYFILE ]] || host_fix_frontend
    fi
}

host_bbr() {
    _host_confirm '启用持久化 fq 与 BBR。' || return
    local available candidate
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control) || return
    if [[ " $available " != *' bbr '* ]]; then
        modprobe tcp_bbr || return
        available=$(sysctl -n net.ipv4.tcp_available_congestion_control) || return
        [[ " $available " == *' bbr '* ]] || { fail '当前内核不支持 BBR'; return 1; }
    fi
    candidate=$(json_temp) || return
    printf '%s\n' 'net.core.default_qdisc=fq' 'net.ipv4.tcp_congestion_control=bbr' >"$candidate" || return
    sysctl -p "$candidate" || return
    install -m 644 "$candidate" /etc/sysctl.d/90-sing-box-manager-bbr.conf
}

# 无法完整表示的字段拒绝整个来源文件，避免删除来源后丢失语义。
# 未支持字段、多个证书/Reality 域名、Unix 握手目标、明文 H2 和 Upgrade early-data 均保留来源原文。
# 字段依据官方文档：xtls.github.io/config/transports/{tls,reality,httpupgrade}.html
# HTTP/2：www.v2fly.org/config/transport/h2.html；目标字段：sing-box.sagernet.org/configuration/shared/{tls,v2ray-transport}/
_host_convert_xray() {
    jq '
    def only($allowed): (keys_unsorted - $allowed) as $extra |
        if ($extra|length)>0 then error("不支持的字段："+($extra|join(","))) else . end;
    def text: if type=="string" then . else error("字段应为字符串") end;
    def texts: if type=="array" and all(.[]; type=="string") then . else error("字段应为字符串数组") end;
    def endpoint:
        text | [capture("^(?:\\[(?<ipv6>[^\\[\\]]+)\\]|(?<host>[^:\\[\\]\\s]+)):(?<port>[0-9]+)$")] |
        if length!=1 then error("Reality dest/target 仅支持明确的主机:端口或 [IPv6]:端口") else .[0] end |
        {server:(.ipv6 // .host),server_port:(.port|tonumber)} |
        if .server_port<1 or .server_port>65535 then error("Reality 握手端口无效") else . end;
    def stream:
        (.security // "none") as $security | (.network // "tcp") as $network |
        (if $network=="tcp" then null
         elif $network=="ws" then "wsSettings"
         elif $network=="grpc" then "grpcSettings"
         elif $network=="http" or $network=="h2" then "httpSettings"
         elif $network=="httpupgrade" then "httpupgradeSettings"
         else error("不支持的传输："+$network) end) as $transport_key |
        (if $security=="none" then null
         elif $security=="tls" then "tlsSettings"
         elif $security=="reality" then "realitySettings"
         else error("不支持的传输安全："+$security) end) as $security_key |
        only(["network","security"]+[$transport_key,$security_key]|map(select(.!=null))) |
        (if $security=="none" then {}
         elif $security=="tls" then
            (.tlsSettings | only(["serverName","alpn","certificates"])) as $tls |
            if ($tls.certificates|type)!="array" or ($tls.certificates|length)!=1 then error("TLS 仅支持一个文件证书，拒绝丢弃其他证书") else . end |
            ($tls.certificates[0] | only(["certificateFile","keyFile","usage"])) as $cert |
            if ($cert.usage // "encipherment")!="encipherment" then error("不支持 TLS 证书 usage") else . end |
            ($tls.serverName // "" | text) as $name |
            if $name=="FromMitM" then error("不支持动态 TLS serverName") else . end |
            {tls:({enabled:true,certificate_path:($cert.certificateFile|text),key_path:($cert.keyFile|text),
                  alpn:($tls.alpn // ["h2","http/1.1"] | texts)} +
                 (if $tls|has("serverName") then {server_name:$name} else {} end))}
         else
            (.realitySettings | only(["privateKey","shortIds","serverNames","dest","target","show","xver"])) as $reality |
            ($reality.serverNames | texts) as $names |
            if ($names|length)!=1 or $names[0]=="" or ($names[0]|contains("*")) then error("Reality serverNames 仅支持一个非空、无通配符域名，拒绝改变允许列表") else . end |
            if ($reality.show // false)!=false or ($reality.xver // 0)!=0 then error("不支持 Reality show/xver 行为") else . end |
            if ($reality|has("dest")) and ($reality|has("target")) then error("Reality dest 与 target 不能同时指定") else . end |
            ($reality.shortIds | texts) as $ids |
            if ($ids|length)==0 or any($ids[]; (test("^(?:[0-9a-fA-F]{2}){0,8}$")|not)) then error("Reality shortIds 应为非空数组，元素为至多 8 字节的十六进制串") else . end |
            {tls:{enabled:true,server_name:$names[0],reality:{enabled:true,
                  handshake:(($reality.dest // $reality.target)|endpoint),
                  private_key:($reality.privateKey|text),short_id:$ids}}}
         end) as $tls_fields |
        (if $network=="tcp" then {}
         elif $network=="ws" then
            (.wsSettings // {} | only(["path","headers"])) as $ws |
            {transport:({type:"ws"}+($ws|{path,headers}|with_entries(select(.value!=null))))}
         elif $network=="grpc" then
            (.grpcSettings // {} | only(["serviceName"])) as $grpc |
            {transport:{type:"grpc",service_name:($grpc.serviceName // "")}}
         elif $network=="http" or $network=="h2" then
            if $security=="none" then error("明文 HTTP/2 与目标 HTTP 传输存在差异，拒绝自动转换") else . end |
            (.httpSettings // {} | only(["host","path","method","headers"])) as $http |
            {transport:({type:"http",host:($http.host // []|texts),path:($http.path // "/"|text),
                         method:($http.method // "PUT"|text)}+
                        (if $http|has("headers") then {headers:$http.headers} else {} end))}
         else
            (.httpupgradeSettings // {} | only(["host","path","headers"])) as $upgrade |
            ($upgrade.path // "/" | text) as $path |
            if $path|test("[?&]ed=") then error("不支持 HTTPUpgrade early data，保留来源") else . end |
            # Xray 入站仅从 headers 使用 Host；不能把客户端请求头变成目标的响应头。
            ($upgrade.headers // {} | to_entries) as $headers |
            if any($headers[]; (.key|ascii_downcase)!="host") or ($headers|length)>1 then error("HTTPUpgrade 入站 headers 仅支持唯一 Host 字段") else . end |
            (if ($headers|length)==1 then $headers[0].value|text else "" end) as $header_host |
            ($upgrade.host // ""|text) as $host |
            if $host!="" and $header_host!="" and $host!=$header_host then error("HTTPUpgrade host 与 headers.Host 冲突") else . end |
            {transport:{type:"httpupgrade",host:(if $host!="" then $host else $header_host end),path:$path}}
         end) + $tls_fields;
    only(["inbounds"]) |
    if (.inbounds|type)!="array" or (.inbounds|length)==0 then error("缺少入站数组") else . end |
    {inbounds:[.inbounds[] |
        only(["tag","listen","port","protocol","settings","streamSettings"]) |
        . as $in |
        (.streamSettings // {} | stream) as $stream |
        {type:(if .protocol=="shadowsocks" then "shadowsocks" else .protocol end),
         tag:.tag, listen:(.listen // "0.0.0.0"), listen_port:(.port|tonumber)} |
        if (.listen_port<1 or .listen_port>65535 or (.listen_port|floor)!=.listen_port) then error("无效端口") else . end |
        if $in.protocol=="vless" or $in.protocol=="vmess" then
            ($in.settings | only(["clients","decryption"])) as $settings |
            if ($settings.decryption // "none")!="none" then error("不支持 decryption") else . end |
            .users=[$settings.clients[] | only(["id","email","alterId","flow"]) |
                if (.alterId // 0)!=0 then error("不支持非零 alterId") else . end |
                {uuid:.id} + (if has("email") then {name:.email} else {} end) +
                (if has("flow") then {flow:.flow} else {} end)]
        elif $in.protocol=="trojan" then
            ($in.settings | only(["clients"])) as $settings |
            .users=[$settings.clients[] | only(["password","email"]) |
                {password:.password}+(if has("email") then {name:.email} else {} end)]
        elif $in.protocol=="shadowsocks" then
            ($in.settings | only(["method","password","network"])) as $settings |
            .method=$settings.method | .password=$settings.password |
            if $settings.network then .network=$settings.network else . end
        elif $in.protocol=="socks" then
            ($in.settings | only(["auth","accounts","udp"])) as $settings |
            if ($settings|has("udp")) then error("不支持 socks udp 开关") else . end |
            if ($settings.auth // "noauth")=="password" then
                .users=[$settings.accounts[] | only(["user","pass"]) | {username:.user,password:.pass}]
            elif ($settings.auth // "noauth")=="noauth" and (($settings.accounts // [])|length)==0 then .
            else error("不支持 socks 认证配置") end
        else error("不支持的协议："+$in.protocol) end |
        . + $stream |
        with_entries(select(.value!=null))]}' "$1" >"$2"
}

host_import() {
    local directory file candidate target failed=0 count=0
    local -a directories=()
    if [[ -n ${SB_IMPORT_DIR:-} ]]; then directories=("$SB_IMPORT_DIR")
    else directories=(/etc/xray/conf /etc/v2ray/conf); fi
    for directory in "${directories[@]}"; do
        [[ -d $directory ]] || continue
        while IFS= read -r -d '' file; do
            count=$((count+1))
            candidate=$(json_temp) || return
            target="$SB_PARTS/import-$(basename "$file")"
            if [[ -e $target ]]; then fail "目标已存在，保留来源：$file" || failed=1; continue; fi
            if ! _host_convert_xray "$file" "$candidate"; then fail "无法完整转换，保留来源：$file" || failed=1; continue; fi
            if documents_commit "$target" "$candidate"; then rm -- "$file" || return
            else fail "校验或应用失败，保留来源：$file" || failed=1; fi
        done < <(find "$directory" -maxdepth 1 -type f -name '*.json' -print0)
    done
    [[ $count != 0 ]] || { fail '未找到 Xray/V2Ray 来源配置'; return 1; }
    return "$failed"
}
