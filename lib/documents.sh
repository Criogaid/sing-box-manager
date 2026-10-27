#!/usr/bin/env bash

# 文档顺序与核心多配置合并顺序保持一致。
documents_list() {
    local file
    [[ ! -f $SB_MAIN ]] || printf '%s\0' "$SB_MAIN"
    [[ -d $SB_PARTS ]] || return 0
    while IFS= read -r -d '' file; do printf '%s\0' "$file"; done < <(find "$SB_PARTS" -maxdepth 1 -type f -name '*.json' -print0 | sort -z)
}

documents_inventory() {
    local file output
    output=$(json_temp) || return
    printf '[]\n' > "$output"
    while IFS= read -r -d '' file; do
        jq --arg file "$file" '[.inbounds // [] | to_entries[] | {file:$file,index:.key,value:.value}]' "$file" > "$output.part" || return
        jq -s '.[0]+.[1]' "$output" "$output.part" > "$output.next" || return
        mv "$output.next" "$output" || return
    done < <(documents_list)
    cat "$output"
}

documents_select() {
    local selector=${1:-} inventory matches count index
    inventory=$(documents_inventory) || return
    matches=$(jq --arg s "$selector" '[.[] | select($s != "" and .value.tag == $s)]' <<< "$inventory") || return
    if [[ $(jq length <<< "$matches") == 0 && -n $selector ]]; then
        matches=$(jq --arg s "$selector" '[.[] | select(.file == $s or (.file|split("/")|last) == $s)]' <<< "$inventory") || return
        if [[ $(jq length <<< "$matches") == 0 ]]; then
            matches=$(jq --arg s "$selector" '[.[] | select(.file|split("/")|last|test($s))]' <<< "$inventory") || { fail '文件名正则无效'; return 1; }
        fi
    elif [[ -z $selector ]]; then
        matches=$(jq '[.[] as $n | select(([.[] | select(.value.detour != null and .value.detour == $n.value.tag)] | length != 1 or .[0].value.type != "shadowtls")) | $n]' <<< "$inventory") || return
    fi
    count=$(jq length <<< "$matches")
    (( count > 0 )) || { fail '没有匹配的入站'; return 1; }
    if (( count == 1 )); then jq '.[0]' <<< "$matches"; return; fi
    local -a choices=()
    while IFS= read -r index; do choices+=("$index"); done < <(jq -r '.[] | "\(.value.tag // "未命名") [\(.file):\(.index)]"' <<< "$matches")
    index=$(choose_index '请选择入站' "${choices[@]}") || return
    jq --argjson i "$index" '.[$i]' <<< "$matches"
}

_documents_inputs() {
    local target=${1:-} candidate=${2:-} file listing
    _DOC_ARGS=() _DOC_FILES=()
    listing=$(json_temp) || return
    documents_list > "$listing" || return
    if [[ -n $target && ! -f $target ]]; then printf '%s\0' "$target" >> "$listing"; fi
    if [[ -f $SB_MAIN || $target == "$SB_MAIN" ]]; then
        if [[ $target == "$SB_MAIN" ]]; then _DOC_FILES+=("$candidate"); else _DOC_FILES+=("$SB_MAIN"); fi
    fi
    while IFS= read -r -d '' file; do
        [[ $file != "$SB_MAIN" ]] || continue
        if [[ $file == "$target" ]]; then _DOC_FILES+=("$candidate"); else _DOC_FILES+=("$file"); fi
    done < <(sort -zu "$listing")
    for file in "${_DOC_FILES[@]}"; do _DOC_ARGS+=(-c "$file"); done
    (( ${#_DOC_ARGS[@]} )) || { fail '没有可合并的配置'; return 1; }
}

documents_merge() {
    _documents_inputs || return
    (cd "$SB_ROOT" && "$SB_CORE" merge "$1" "${_DOC_ARGS[@]}") >/dev/null || { fail '核心合并配置失败'; return 1; }
}

documents_check() {
    jq -e 'type == "object"' "$2" >/dev/null || { fail '候选配置必须为 JSON 对象'; return 1; }
    _documents_inputs "$1" "$2" || return
    jq -e -s '
        [.[] | .inbounds[]?] as $inbounds |
        [$inbounds[] | .tag // empty] as $tags |
        all($inbounds[]; .detour == null or .detour == "" or
            (.detour as $target | $tags | index($target) != null))
    ' "${_DOC_FILES[@]}" >/dev/null || { fail '入站 detour 必须指向完整候选配置中存在的入站 tag'; return 1; }
    (cd "$SB_ROOT" && "$SB_CORE" check "${_DOC_ARGS[@]}") || { fail '完整候选配置检查失败'; return 1; }
}

_documents_write() {
    local target=$1 candidate=$2 temporary
    mkdir -p "$(dirname "$target")" || return
    temporary=$(mktemp "$(dirname "$target")/.sb-write.XXXXXX") || return
    if ! cat "$candidate" > "$temporary"; then rm -f "$temporary"; return 1; fi
    if [[ -e $target ]]; then
        chmod --reference="$target" "$temporary" || { rm -f "$temporary"; return 1; }
    else chmod 600 "$temporary" || { rm -f "$temporary"; return 1; }; fi
    mv -f "$temporary" "$target"
}

documents_commit() {
    local target=$1 candidate=$2 before
    if [[ -f $target ]] && jq -e -s '.[0] == .[1]' "$target" "$candidate" >/dev/null; then return 0; fi
    before=$(json_temp) || return
    if [[ -f $target ]]; then cp "$target" "$before" || return; else printf '{}\n' > "$before"; fi
    documents_check "$target" "$candidate" || return
    frontend_reconcile "$before" "$candidate" check || return
    if [[ $target != "$SB_MAIN" ]] && jq -e 'keys == ["inbounds"] and .inbounds == []' "$candidate" >/dev/null; then
        rm -f "$target" || return
    else _documents_write "$target" "$candidate" || return; fi
    frontend_reconcile "$before" "$candidate" apply || return
    host_service restart sing-box
}
