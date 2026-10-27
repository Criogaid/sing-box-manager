#!/usr/bin/env bash

# 只定位文本中的词元；语义和完整语法仍交给官方适配器。
_front_tokens() {
    local file=$1 i=0 start ch quote token length
    _FT_TEXT=$(cat "$file"; printf '.') || return
    _FT_TEXT=${_FT_TEXT%.}
    _FT_VALUE=() _FT_START=() _FT_END=()
    length=${#_FT_TEXT}
    while (( i < length )); do
        ch=${_FT_TEXT:i:1}
        if [[ $ch == ' ' || $ch == $'\t' || $ch == $'\r' ]]; then i=$((i+1)); continue; fi
        start=$i
        if [[ $ch == $'\n' ]]; then token=$'\n'; i=$((i+1))
        elif [[ $ch == '#' ]]; then
            while (( i < length )) && [[ ${_FT_TEXT:i:1} != $'\n' ]]; do i=$((i+1)); done
            continue
        else
            token= quote=
            while (( i < length )); do
                ch=${_FT_TEXT:i:1}
                if [[ -n $quote ]]; then
                    if [[ $ch == "$quote" ]]; then quote=
                    elif [[ $ch == '\' && $quote == '"' ]]; then i=$((i+1)); token+=${_FT_TEXT:i:1}
                    else token+=$ch; fi
                elif [[ $ch == '"' || $ch == '`' ]]; then quote=$ch
                elif [[ $ch == ' ' || $ch == $'\t' || $ch == $'\n' || $ch == $'\r' ]]; then break
                else token+=$ch; fi
                i=$((i+1))
            done
            [[ -z $quote ]] || { fail 'Caddyfile 引号未闭合'; return 1; }
        fi
        if [[ ( $token == '{' || $token == '}' ) && ${_FT_TEXT:start:i-start} != "$token" ]]; then token="quoted:$token"; fi
        _FT_VALUE+=("$token") _FT_START+=("$start") _FT_END+=("$i")
    done
}

# 读取 import 的实际文件，未导入的旧文件不参与关联。
_front_files() {
    local file=$1 depth=${2:-0} i pattern match
    (( depth < 24 )) || { fail 'Caddy 导入层级过深'; return 1; }
    [[ -f $file ]] || return 0
    printf '%s\0' "$file"
    _front_tokens "$file" || return
    local -a imports=()
    for ((i=0;i<${#_FT_VALUE[@]}-1;i++)); do
        if [[ ${_FT_VALUE[i]} == import ]]; then
            pattern=${_FT_VALUE[i+1]}
            [[ $pattern == /* || $pattern =~ ^[A-Za-z]:/ ]] || pattern="$(dirname "$file")/$pattern"
            imports+=("$pattern")
        fi
    done
    for pattern in "${imports[@]}"; do
        while IFS= read -r match; do
            [[ -f $match ]] || continue
            _front_files "$match" "$((depth+1))" || return
        done < <(compgen -G "$pattern" | sort)
    done
}

_front_address() {
    local address=$1
    address=${address%,}
    _FA_PORT=443 _FA_SCHEME=''
    case $address in http://*) _FA_PORT=80; _FA_SCHEME=http://; address=${address#http://};; https://*) _FA_SCHEME=https://; address=${address#https://};; esac
    if [[ $address =~ ^([^/:]+):([0-9]+)$ ]]; then _FA_HOST=${BASH_REMATCH[1]}; _FA_PORT=${BASH_REMATCH[2]}
    elif [[ $address =~ ^[^/:,{}\ ]+$ ]]; then _FA_HOST=$address
    else return 1; fi
}

_front_scan_file() {
    local file=$1 i j k depth=0 site=-1 handle=-1 host='' port=0 scheme='' path='' transport upstream end block close
    local -a stack=() close_at=()
    _front_tokens "$file" || return
    for ((i=0;i<${#_FT_VALUE[@]};i++)); do
        case ${_FT_VALUE[i]} in
            '{') stack+=("$i");;
            '}') (( ${#stack[@]} )) || { fail 'Caddyfile 块未匹配'; return 1; }
                 j=${stack[${#stack[@]}-1]}; close_at[j]=$i; unset 'stack[${#stack[@]}-1]';;
        esac
    done
    stack=()
    for ((i=0;i<${#_FT_VALUE[@]};i++)); do
        case ${_FT_VALUE[i]} in
            '{')
                stack+=("$i"); depth=${#stack[@]}
                j=$((i-1)); while (( j > 0 )) && [[ ${_FT_VALUE[j-1]} != $'\n' ]]; do j=$((j-1)); done
                if (( depth == 1 )); then
                    site=$j; host=''; handle=-1; path=''
                    if (( i == j+1 )) && _front_address "${_FT_VALUE[j]}"; then host=$_FA_HOST; port=$_FA_PORT; scheme=$_FA_SCHEME; fi
                elif [[ ${_FT_VALUE[j]} == handle || ${_FT_VALUE[j]} == handle_path ]]; then
                    handle=$j; path=''
                    if (( i == j+2 )); then path=${_FT_VALUE[j+1]}; fi
                fi;;
            '}')
                if (( ${#stack[@]} )); then
                    block=${stack[${#stack[@]}-1]}; unset 'stack[${#stack[@]}-1]'
                    if (( handle >= 0 && block > handle )); then
                        j=$((block-1)); while (( j > handle )) && [[ ${_FT_VALUE[j]} != $'\n' ]]; do j=$((j-1)); done
                        if (( j <= handle )); then handle=-1; path=''; fi
                    fi
                fi;;
            reverse_proxy)
                end=$((i+1)); while (( end < ${#_FT_VALUE[@]} )) && [[ ${_FT_VALUE[end]} != $'\n' && ${_FT_VALUE[end]} != '{' ]]; do end=$((end+1)); done
                for ((j=i+1;j<end;j++)); do
                    upstream=${_FT_VALUE[j]}
                    if [[ $upstream =~ ^(h2c://|http://)?(127\.0\.0\.1|localhost):([0-9]+)$ ]]; then
                        [[ -n $host ]] || { fail '后端所在站点地址存在歧义'; return 1; }
                        local route_path=$path path_index=$((handle>=0?handle+1:i)) versions_start=-1 versions_end=-1 version_last
                        if (( end == i+3 )) && [[ ${_FT_VALUE[i+1]} == /* ]]; then
                            route_path=${_FT_VALUE[i+1]}; path_index=$((i+1))
                        elif (( end != i+2 )); then fail '反代存在多个目标或不支持的匹配器，无法安全修改'; return 1; fi
                        transport=http; [[ $upstream != h2c://* ]] || transport=h2c
                        close=$((end-1)); [[ ${_FT_VALUE[end]:-} != '{' ]] || close=${close_at[end]}
                        if [[ ${_FT_VALUE[end]:-} == '{' ]]; then
                            for ((k=end;k<close;k++)); do
                                if [[ ${_FT_VALUE[k]} == versions ]]; then
                                    versions_start=${_FT_START[k+1]}; version_last=$((k+1))
                                    while [[ ${_FT_VALUE[version_last+1]:-$'\n'} != $'\n' ]]; do version_last=$((version_last+1)); done
                                    versions_end=${_FT_END[version_last]}
                                    [[ ${_FT_VALUE[k+1]:-} != h2c ]] || transport=h2c
                                fi
                            done
                        fi
                        block=$i
                        jq -nc --arg file "$file" --arg host "$host" --argjson port "$port" --argjson backend "${BASH_REMATCH[3]}" \
                            --arg path "$route_path" --arg scheme "$scheme" --arg transport "$transport" --arg upstream "$upstream" \
                            --argjson host_start "${_FT_START[site]}" --argjson host_end "${_FT_END[site]}" \
                            --argjson site_end "${_FT_END[${close_at[${stack[0]}]}]}" \
                            --argjson upstream_start "${_FT_START[j]}" --argjson upstream_end "${_FT_END[j]}" \
                            --argjson path_start "${_FT_START[path_index]}" --argjson path_end "${_FT_END[path_index]}" \
                            --argjson versions_start "$versions_start" --argjson versions_end "$versions_end" \
                            --argjson remove_start "${_FT_START[block]}" --argjson remove_end "${_FT_END[close]}" \
                            '{file:$file,host:$host,port:$port,backend:$backend,path:$path,scheme:$scheme,transport:$transport,upstream:$upstream,host_start:$host_start,host_end:$host_end,site_end:$site_end,upstream_start:$upstream_start,upstream_end:$upstream_end,path_start:$path_start,path_end:$path_end,versions_start:$versions_start,versions_end:$versions_end,remove_start:$remove_start,remove_end:$remove_end}' || return
                    fi
                done;;
        esac
    done
}

_front_routes() {
    local files file output
    output=$(json_temp) || return
    files=$(json_temp) || return
    _front_files "$SB_CADDYFILE" > "$files" || return
    while IFS= read -r -d '' file; do _front_scan_file "$file" >> "$output" || return; done < <(sort -zu "$files")
    jq -s '.' "$output"
}

_front_match() {
    local inbound=$1 routes=$2 result
    result=$(jq --argjson n "$inbound" '[.[] | select($n.transport.type == "ws" or $n.transport.type == "http" or $n.transport.type == "httpupgrade") | select(.backend == $n.listen_port) | select(($n.listen // "127.0.0.1") == "127.0.0.1" or $n.listen == "localhost" or $n.listen == "::" or $n.listen == "0.0.0.0") ]' <<< "$routes") || return
    case $(jq length <<< "$result") in
        0) printf 'null\n';;
        1) jq '.[0]' <<< "$result";;
        *) fail '同一后端对应多个 Caddy 路由，拒绝猜测'; return 1;;
    esac
}

frontend_lookup() {
    local routes inbound route
    inbound=$(jq -ce 'select(type == "object" and (has("inbounds")|not) and (.type|type)=="string")' "$1") || { fail '前端查询需要单个入站对象'; return 1; }
    routes=$(_front_routes) || return
    route=$(_front_match "$inbound" "$routes") || return
    jq 'if . == null then null else {file,host,port,backend,path,transport} end' <<< "$route"
}

_front_stage() {
    _FR_STAGE=$(mktemp -d "$SB_WORK/caddy.XXXXXX") || return
    mkdir -p "$_FR_STAGE/root" || return
    [[ ! -d $SB_CADDY_ROOT ]] || cp -a "$SB_CADDY_ROOT/." "$_FR_STAGE/root/" || return
    _FR_EDITS=$(json_temp) || return
    printf '[]\n' > "$_FR_EDITS"
}

_front_edit_range() {
    local route=$1 start=$2 end=$3 text=$4
    jq --argjson r "$route" --argjson a "$start" --argjson b "$end" --arg text "$text" '.+[{file:$r.file,start:$a,end:$b,text:$text}]' "$_FR_EDITS" > "$_FR_EDITS.next" && mv "$_FR_EDITS.next" "$_FR_EDITS"
}

_front_replace_route() {
    local route=$1 field=$2 text=$3
    _front_edit_range "$route" "$(jq -r ".${field}_start" <<< "$route")" "$(jq -r ".${field}_end" <<< "$route")" "$text"
}

_front_materialize() {
    local file staged edits content start end replacement edit
    while IFS= read -r file; do
        [[ $file == "$SB_CADDY_ROOT/"* ]] || { fail '只能修改 Caddy 根目录内的站点文件'; return 1; }
        [[ ! -L $file ]] || { fail '拒绝覆盖符号链接站点'; return 1; }
        staged="$_FR_STAGE/root/${file#"$SB_CADDY_ROOT/"}"
        content=$(cat "$file"; printf '.'); content=${content%.}
        edits=$(jq -c --arg f "$file" '[.[]|select(.file==$f)]|unique|sort_by(.start)|reverse' "$_FR_EDITS") || return
        local boundary=${#content}
        while IFS= read -r edit; do
            start=$(jq -r .start <<< "$edit"); end=$(jq -r .end <<< "$edit")
            (( end <= boundary )) || { fail 'Caddy 修改范围重叠'; return 1; }
            replacement=$(jq -r '.text + "."' <<< "$edit"); replacement=${replacement%.}
            content=${content:0:start}$replacement${content:end}; boundary=$start
        done < <(jq -c '.[]' <<< "$edits")
        printf '%s' "$content" > "$staged" || return
    done < <(jq -r '.[].file' "$_FR_EDITS" | sort -u)
}

# 验证副本只改 import 的绝对路径；提交时保留原始路径和其他字节。
_front_validate() {
    local validation file i path text
    validation="$_FR_STAGE/validate"
    cp -a "$_FR_STAGE/root" "$validation" || return
    while IFS= read -r -d '' file; do
        _front_tokens "$file" || return
        text=$_FT_TEXT
        for ((i=${#_FT_VALUE[@]}-2;i>=0;i--)); do
            if [[ ${_FT_VALUE[i]} == import && ${_FT_VALUE[i+1]} == "$SB_CADDY_ROOT/"* ]]; then
                path="$validation/${_FT_VALUE[i+1]#"$SB_CADDY_ROOT/"}"
                text=${text:0:${_FT_START[i+1]}}\"$path\"${text:${_FT_END[i+1]}}
            fi
        done
        printf '%s' "$text" > "$file" || return
    done < <(find "$validation" -type f \( -name 'Caddyfile' -o -name '*.conf' -o -name '*.add' \) -print0)
    "$SB_CADDY" adapt --adapter caddyfile --config "$validation/${SB_CADDYFILE#"$SB_CADDY_ROOT/"}" --validate > "$_FR_STAGE/adapted.json" || { fail '完整 Caddy 候选适配失败'; return 1; }
}

_front_publish() {
    local file target changed=0
    while IFS= read -r -d '' file; do
        target="$SB_CADDY_ROOT/${file#"$_FR_STAGE/root/"}"
        if [[ ! -f $target ]] || ! cmp -s "$file" "$target"; then
            _documents_write "$target" "$file" || return
            changed=1
        fi
    done < <(find "$_FR_STAGE/root" -type f -print0)
    (( changed == 0 )) || host_service restart caddy
}

frontend_reconcile() {
    local before=$1 after=$2 mode=$3 routes entry old new route backend path upstream tag
    [[ $mode == check || $mode == apply ]] || { fail '前端模式必须为 check 或 apply'; return 1; }
    routes=$(_front_routes) || return
    [[ $routes != '[]' ]] || return 0
    _front_stage || return
    while IFS= read -r entry; do
        old=$(jq -c .value <<< "$entry")
        route=$(_front_match "$old" "$routes") || return
        [[ $route != null ]] || continue
        tag=$(jq -r '.tag // ""' <<< "$old")
        new=$(jq -c --arg tag "$tag" --argjson i "$(jq .key <<< "$entry")" 'if $tag != "" then [.inbounds[]? | select(.tag == $tag)] | if length > 1 then error("标签重复") else .[0] end else .inbounds[$i] // null end' "$after") || return
        local type listen
        type=$(jq -r '.transport.type // ""' <<< "$new")
        if [[ $new == null || ( $type != ws && $type != http && $type != httpupgrade ) ]]; then
            _front_replace_route "$route" remove '' || return
            continue
        fi
        if jq -e '.tls.enabled == true' <<< "$new" >/dev/null; then fail '现有明文反代不能连接启用 TLS 的后端'; return 1; fi
        listen=$(jq -r '.listen // ""' <<< "$new")
        case $listen in 127.0.0.1|localhost|0.0.0.0) ;; *) fail '关联前端需要监听 127.0.0.1、localhost 或 0.0.0.0'; return 1;; esac
        backend=$(jq -r '.listen_port // empty' <<< "$new")
        [[ $backend =~ ^[0-9]+$ ]] && (( backend > 0 && backend < 65536 )) || { fail '反代后端端口无效'; return 1; }
        upstream=$(jq -r .upstream <<< "$route"); upstream=${upstream#h2c://}; upstream=${upstream#http://}; upstream=${upstream%:*}:$backend
        if [[ $type == http && $(jq .versions_start <<< "$route") == -1 ]]; then upstream="h2c://$upstream"; fi
        if [[ $(jq .versions_start <<< "$route") != -1 ]]; then
            if [[ $type == http ]]; then _front_replace_route "$route" versions h2c || return
            else _front_replace_route "$route" versions 1.1 || return; fi
        fi
        _front_replace_route "$route" upstream "$upstream" || return
        path=$(jq -r '.transport.path // ""' <<< "$new")
        if [[ $path != "$(jq -r '.transport.path // ""' <<< "$old")" ]]; then
            [[ -n $(jq -r .path <<< "$route") && $path == /* && $path != *[$'\r\n\t "`{}']* ]] || { fail '无法安全修改当前 Caddy 路径'; return 1; }
            _front_replace_route "$route" path "$path" || return
        fi
    done < <(jq -c '.inbounds // [] | to_entries[]' "$before")
    [[ $(jq length "$_FR_EDITS") != 0 ]] || return 0
    _front_materialize && _front_validate || return
    [[ $mode == check ]] || _front_publish
}

frontend_create() {
    local inbound=$1 host=$2 port=$3 mode=$4 node backend path type site main
    [[ $mode == check || $mode == apply ]] || { fail '前端模式无效'; return 1; }
    [[ $host =~ ^[A-Za-z0-9.-]+$ && $port =~ ^[0-9]+$ ]] && (( port > 0 && port < 65536 )) || { fail '站点地址或端口无效'; return 1; }
    node=$(jq -ce 'select(type == "object" and (has("inbounds")|not) and (.type|type)=="string")' "$inbound") || { fail '创建前端需要单个入站'; return 1; }
    jq -e '(.listen == "127.0.0.1" or .listen == "localhost") and (.tls.enabled != true)' <<< "$node" >/dev/null || { fail '前端需要明文回环后端'; return 1; }
    backend=$(jq -r '.listen_port' <<< "$node"); type=$(jq -r '.transport.type' <<< "$node"); path=$(jq -r '.transport.path // "/"' <<< "$node")
    [[ $backend =~ ^[0-9]+$ && $path == /* && $path != *[$'\r\n\t "`{}']* ]] && (( backend > 0 && backend < 65536 )) || { fail '后端端口或路径无效'; return 1; }
    case $type in ws|httpupgrade) ;; http) backend="h2c://127.0.0.1:$backend";; *) fail '此传输不能创建前端'; return 1;; esac
    [[ $backend == h2c://* ]] || backend="127.0.0.1:$backend"
    [[ $(frontend_lookup "$inbound") == null ]] || { fail '入站已有前端'; return 1; }
    _front_stage || return
    site="$SB_SITES/managed-${host}-${port}.conf"
    [[ ! -e $site ]] || { fail '站点文件已存在'; return 1; }
    mkdir -p "$_FR_STAGE/root/${SB_SITES#"$SB_CADDY_ROOT/"}" || return
    printf '%s:%s {\n    handle %s {\n        reverse_proxy %s\n    }\n}\n' "$host" "$port" "$path" "$backend" > "$_FR_STAGE/root/${site#"$SB_CADDY_ROOT/"}" || return
    main="$_FR_STAGE/root/${SB_CADDYFILE#"$SB_CADDY_ROOT/"}"
    mkdir -p "$(dirname "$main")" || return
    if ! _front_import_covers "$site"; then printf '\nimport "%s"\n' "$site" >> "$main" || return; fi
    _front_validate || return
    [[ $mode == check ]] || _front_publish
}

frontend_edit() {
    local route routes node field=$2 value=$3 text
    route=$(frontend_lookup "$1") || return
    [[ $route != null ]] || { fail '没有关联的 Caddy 前端'; return 1; }
    routes=$(_front_routes) || return
    route=$(jq -c --argjson r "$route" '.[] | select(.file==$r.file and .backend==$r.backend and .path==$r.path)' <<< "$routes") || return
    _front_stage || return
    case $field in
        port) [[ $value =~ ^[0-9]+$ ]] && (( value > 0 && value < 65536 )) || { fail '公网端口无效'; return 1; }
              text="$(jq -r .scheme <<< "$route")$(jq -r .host <<< "$route"):$value"; _front_replace_route "$route" host "$text" || return;;
        host) [[ $value =~ ^[A-Za-z0-9.-]+$ ]] || { fail '域名无效'; return 1; }
              text="$(jq -r .scheme <<< "$route")$value:$(jq -r .port <<< "$route")"; _front_replace_route "$route" host "$text" || return;;
        web)
            [[ $value =~ ^(https?://)?[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || { fail '伪装反代地址无效'; return 1; }
            # 只替换同站点内唯一的非节点反代，不重建站点块。
            _front_tokens "$(jq -r .file <<< "$route")" || return
            local i count=0 selected=-1 start finish
            start=$(jq -r .host_start <<< "$route"); finish=$(jq -r .site_end <<< "$route")
            for ((i=0;i<${#_FT_VALUE[@]}-1;i++)); do
                if (( _FT_START[i] > start && _FT_END[i] < finish )) && [[ ${_FT_VALUE[i]} == reverse_proxy && ${_FT_VALUE[i+1]} != "$(jq -r .upstream <<< "$route")" ]]; then
                    [[ ${_FT_VALUE[i+2]:-} == $'\n' || ${_FT_VALUE[i+2]:-} == '{' ]] || { fail '伪装反代目标存在歧义'; return 1; }
                    count=$((count+1)); selected=$((i+1))
                fi
            done
            (( count == 1 )) || { fail '伪装反代不是唯一目标'; return 1; }
            _front_edit_range "$route" "${_FT_START[selected]}" "${_FT_END[selected]}" "$value" || return;;
        *) fail '前端字段无效'; return 1;;
    esac
    _front_materialize && _front_validate && _front_publish
}

_front_import_covers() {
    local site=$1 files file i pattern depth
    files=$(json_temp) || return
    _front_files "$SB_CADDYFILE" > "$files" || return
    while IFS= read -r -d '' file; do
        _front_tokens "$file" || return
        depth=0
        for ((i=0;i<${#_FT_VALUE[@]}-1;i++)); do
            case ${_FT_VALUE[i]} in '{') depth=$((depth+1));; '}') depth=$((depth-1));; esac
            if [[ ${_FT_VALUE[i]} == import && $depth == 0 ]]; then
                pattern=${_FT_VALUE[i+1]}
                [[ $pattern == /* || $pattern =~ ^[A-Za-z]:/ ]] || pattern="$(dirname "$file")/$pattern"
                if [[ $site == $pattern ]]; then return 0; fi
            fi
        done
    done < "$files"
    return 1
}
