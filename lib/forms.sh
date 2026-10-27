#!/usr/bin/env bash

_forms_jq() { jq -L "$SB_PROJECT/lib" "$@"; }

forms_init() {
    if [[ -n ${SB_SCHEMA:-} && -s $SB_SCHEMA ]]; then return 0; fi
    SB_SCHEMA=$SB_WORK/forms-schema.json
    [[ ! -s $SB_SCHEMA ]] || return 0
    local candidate
    candidate=$(json_temp) || return
    if ! "$SB_CORE" schema -o "$candidate"; then
        fail '无法生成当前核心的 schema'; return 1
    fi
    _forms_jq -e 'type == "object" and (.properties | type == "object")' "$candidate" >/dev/null || {
        fail '核心 schema 无效'; return 1;
    }
    mv -- "$candidate" "$SB_SCHEMA"
}

_forms_query() {
    local node=$1 filter=$2
    shift 2
    _forms_jq -n --slurpfile root "$SB_SCHEMA" --argjson node "$node" "$@" \
        "include \"schema\"; \$node | $filter"
}

forms_definition() {
    forms_init || return
    local name=$1 type=${2:-} node
    case $name in
        Inbound|DNSServer|DNS)
            node=$(_forms_jq -c --arg name "$name" '."$defs"[$name] // error("schema 缺少定义")' "$SB_SCHEMA") || return;;
        Config)
            node=$(_forms_jq -c '{type:"object",properties:(.properties | {inbounds,dns}),additionalProperties:false}' "$SB_SCHEMA") || return;;
        *) fail '未知表单定义'; return 1;;
    esac
    if [[ -z $type ]]; then printf '%s\n' "$node"; return; fi
    _forms_query "$node" '[variants($root[0])[] | select((.properties.type | resolve($root[0])) | if has("const") then .const == $type else (.enum // [] | index($type)) != null end)] | if length == 0 then error("类型不存在") elif length == 1 then .[0] else {oneOf:.} end' --arg type "$type" -c
}

forms_types() {
    case $1 in Inbound|DNSServer) ;; *) fail '类型列表仅支持入站或 DNS 服务器'; return 1;; esac
    local node
    node=$(forms_definition "$1") || return
    _forms_query "$node" '[variants($root[0])[] | .properties.type | resolve($root[0]) | if has("const") then .const else .enum[] end] | unique[]' -r
}

_forms_replace_path() {
    local file=$1 path=$2 value=$3 tmp
    tmp=$(json_temp) || return
    _forms_jq --argjson path "$path" --argjson value "$value" 'setpath($path;$value)' "$file" > "$tmp" || return
    cat "$tmp" > "$file"
}

forms_set() {
    forms_init || return
    local node=$1 file=$2 field=$3 text=$4 value
    [[ -n $field && $field != .* && $field != *. && $field != *..* ]] || { fail '字段路径不能为空'; return 1; }
    value=$(_forms_jq -c --slurpfile root "$SB_SCHEMA" --argjson node "$node" --arg field "$field" --arg text "$text" '
        include "schema";
        . as $data | ($field | split(".")) as $path |
        ($node | field_node($root[0];$data;$path)) |
        parse_scalar($root[0];$text;($data | getpath($path)))' "$file") || return
    _forms_replace_path "$file" "$( _forms_jq -cn --arg field "$field" '$field | split(".")' )" "$value"
}

forms_show() {
    _forms_jq -r 'include "schema";
        def display: if type == "string" then tojson | .[1:-1] else tostring end;
        redact | . as $data |
        ([], paths) as $p | ($data | getpath($p)) as $v |
        select(($v | type) != "object" and ($v | type) != "array" or ($v | length) == 0) |
        (if ($p | length) == 0 then "$" else $p | map(if type == "number" then "[\(.)]" else display end) | join(".") end) + " = " + ($v | display)' "$1"
}

# 每层只处理一个节点；所有递归共享同一草稿，任意失败由最外层丢弃。
_forms_edit_node() {
    local node=$1 file=$2 path=$3 secret=${4:-0}
    local current present variants count index selected kind value answer key child childpath action
    local -a choices=() keys=()
    current=$(_forms_jq -c --argjson path "$path" 'getpath($path)' "$file") || return
    present=$(_forms_jq -r --argjson path "$path" 'if ($path|length)==0 then true else getpath($path[0:-1]) | if type=="object" or type=="array" then has($path[-1]) else false end end' "$file") || return
    printf '\n字段 %s，已配置：%s\n' "$path" "$present" >&2
    if [[ $secret == 1 ]]; then printf '<已隐藏>\n' >&2
    else _forms_jq -n --argjson value "$current" 'include "schema"; $value | redact' >&2 || return; fi
    variants=$(_forms_query "$node" 'variants($root[0])' -c) || return
    count=$(_forms_jq -r 'length' <<< "$variants") || return
    if ((count > 1)); then
        while IFS= read -r answer; do choices+=("$answer"); done < <(
            _forms_jq -r --argjson current "$current" '.[] | ((.title // .type // "分支") | tostring) + " " + ((.properties // {} | with_entries(select(.value.const != null or .value.enum != null))) | tojson) + (if .type == ($current|type) then "（当前类型）" else "" end)' <<< "$variants")
        index=$(choose_index '选择类型或分支（q 取消整个草稿）' "${choices[@]}") || return
    else index=0; fi
    selected=$(_forms_jq -c --argjson i "$index" '.[$i]' <<< "$variants") || return
    kind=$(_forms_query "$selected" 'kind' -r) || return
    case $kind in
        object|array)
            if [[ $( _forms_jq -r 'type' <<< "$current" ) != "$kind" ]]; then
                if [[ $kind == object ]]; then current='{}'; else current='[]'; fi
                _forms_replace_path "$file" "$path" "$current" || return
            fi
            if [[ $kind == object ]]; then
                # 仅判别字段自动跟随分支，其他旧字段留给用户显式编辑或删除。
                while IFS= read -r key; do keys+=("$key"); done < <(_forms_jq -r '.properties // {} | keys_unsorted[] | @base64' <<< "$selected")
                for key in "${keys[@]}"; do
                    key=$(_forms_jq -rn --arg key "$key" '$key | @base64d') || return
                    child=$(_forms_jq -c --arg key "$key" '.properties[$key]' <<< "$selected") || return
                    child=$(_forms_query "$child" 'resolve($root[0])' -c) || return
                    childpath=$(_forms_jq -cn --argjson p "$path" --arg key "$key" '$p + [$key]') || return
                    if ! _forms_jq -e --arg key "$key" --argjson variants "$variants" '
                        ((.required // [] | index($key)) != null) or
                        (($variants | length) > 1 and
                         all($variants[]; (.properties[$key] // {} | has("const") or has("enum"))) and
                         ([$variants[] | .properties[$key] | {const,enum}] | unique | length > 1))' <<< "$selected" >/dev/null; then continue; fi
                    if _forms_jq -e 'has("const")' <<< "$child" >/dev/null; then
                        value=$(_forms_jq -c '.const' <<< "$child") || return
                        _forms_replace_path "$file" "$childpath" "$value" || return
                    elif _forms_jq -e 'has("enum")' <<< "$child" >/dev/null; then
                        value=$(_forms_jq -c --argjson p "$childpath" 'getpath($p)' "$file") || return
                        if ! _forms_jq -e --argjson value "$value" '.enum | index($value) != null' <<< "$child" >/dev/null; then
                            _forms_edit_node "$child" "$file" "$childpath" "$secret" || return
                        fi
                    fi
                done
            fi
            while :; do
                current=$(_forms_jq -c --argjson path "$path" 'getpath($path)' "$file") || return
                if [[ $kind == object ]]; then
                    value=$(_forms_jq -c --slurpfile root "$SB_SCHEMA" --argjson current "$current" 'include "schema"; [.[] | select(discriminator_match($root[0];$current;null))] | if length == 1 then .[0] else null end' <<< "$variants") || return
                    if [[ $value != null ]]; then selected=$value; fi
                fi
                choices=('完成此层' '添加字段或列表项')
                keys=()
                if [[ $kind == object ]]; then
                    while IFS= read -r key; do keys+=("$key"); done < <(_forms_jq -r --argjson data "$current" '((.properties // {} | keys_unsorted) + ($data | keys_unsorted)) | unique[] | @base64' <<< "$selected")
                    for key in "${keys[@]}"; do
                        answer=$(_forms_jq -rn --arg key "$key" '$key | @base64d | @json') || return
                        choices+=("$answer")
                    done
                else
                    count=$(_forms_jq -r 'length' <<< "$current") || return
                    for ((index=0; index<count; index++)); do keys+=("$index"); choices+=("[$index]"); done
                fi
                index=$(choose_index '选择字段（q 取消整个草稿）' "${choices[@]}") || return
                if ((index == 0)); then return 0; fi
                if ((index == 1)); then
                    if [[ $kind == object ]]; then
                        key=$(read_text '新字典键（q 取消）：') || return
                        [[ $key != q && -n $key ]] || { fail '已取消'; return 1; }
                        key=$(_forms_jq -cn --arg key "$key" '$key') || return
                    else key=$(_forms_jq -r 'length' <<< "$current") || return; fi
                    action=0
                else
                    key=${keys[index-2]}
                    if [[ $kind == object ]]; then key=$(_forms_jq -cn --arg key "$key" '$key | @base64d') || return; fi
                    action=$(choose_index '字段操作' '编辑' '删除（省略）') || return
                fi
                childpath=$(_forms_jq -cn --argjson p "$path" --argjson key "$key" '$p + [$key]') || return
                if ((action == 1)); then
                    value=$(_forms_jq -c --argjson key "$key" 'del(.[$key])' <<< "$current") || return
                    _forms_replace_path "$file" "$path" "$value" || return
                    continue
                fi
                if [[ $kind == object ]]; then
                    child=$(_forms_jq -c --argjson key "$key" --argjson variants "$variants" --argjson current "$current" '
                        if (.properties // {} | has($key)) then .properties[$key]
                        elif ($current | has($key)) and any($variants[]; (.properties // {} | has($key))) then
                            {anyOf: [$variants[] | select(.properties // {} | has($key)) | .properties[$key]]}
                        elif .additionalProperties == false then error("此对象不允许新增字段")
                        else .additionalProperties // {} end' <<< "$selected") || return
                else child=$(_forms_jq -c '.items // {}' <<< "$selected") || return; fi
                answer=$secret
                if [[ $key == '"private_key"' ]]; then answer=1; fi
                _forms_edit_node "$child" "$file" "$childpath" "$answer" || return
            done;;
        *)
            if _forms_jq -e 'has("const") or has("enum")' <<< "$selected" >/dev/null; then
                value=$(_forms_jq -c 'if has("const") then [.const] else .enum end' <<< "$selected") || return
                choices=()
                while IFS= read -r answer; do choices+=("$answer"); done < <(_forms_jq -c '.[]' <<< "$value")
                index=$(choose_index '选择值（q 取消整个草稿）' "${choices[@]}") || return
                value=$(_forms_jq -c --argjson i "$index" '.[$i]' <<< "$value") || return
            else
                answer=$(read_text '输入标量值（q 取消整个草稿）：') || return
                [[ $answer != q ]] || { fail '已取消'; return 1; }
                value=$(_forms_query "$selected" 'parse_scalar($root[0];$text;$current)' --arg text "$answer" --argjson current "$current" -c) || return
            fi
            _forms_replace_path "$file" "$path" "$value";;
    esac
}

forms_edit() {
    forms_init || return
    local draft
    draft=$(json_temp) || return
    _forms_jq '.' "$2" > "$draft" || return
    _forms_edit_node "$1" "$draft" '[]' || { fail '编辑已取消，原文件未修改'; return 1; }
    cat "$draft" > "$2"
}
