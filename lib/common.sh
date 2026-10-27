#!/usr/bin/env bash
# 通用交互与进程环境；不在加载模块时访问活动配置。
fail() { printf '错误：%s\n' "$*" >&2; return 1; }

runtime_init() {
    : "${SB_PROJECT:=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
    : "${SB_ROOT:=/etc/sing-box}"
    : "${SB_CORE:=$SB_ROOT/bin/sing-box}"
    SB_MAIN=$SB_ROOT/config.json
    SB_PARTS=$SB_ROOT/conf
    SB_META=$SB_ROOT/script.json
    : "${SB_CADDY_ROOT:=/etc/caddy}"
    : "${SB_CADDY:=/usr/local/bin/caddy}"
    SB_CADDYFILE=$SB_CADDY_ROOT/Caddyfile
    SB_SITES=$SB_CADDY_ROOT/sing-box
    SB_VERSION=$(cat -- "$SB_PROJECT/VERSION") || return
    if [[ ! ${SB_SERVICE_MANAGER:-} ]]; then
        if command -v systemctl >/dev/null 2>&1; then SB_SERVICE_MANAGER=systemd
        elif command -v rc-service >/dev/null 2>&1; then SB_SERVICE_MANAGER=openrc
        else SB_SERVICE_MANAGER=none; fi
    fi
    case $SB_SERVICE_MANAGER in systemd|openrc|none) ;; *) fail '不支持的服务管理方式'; return 1 ;; esac
    if [[ ! ${SB_WORK:-} ]]; then
        SB_WORK=$(mktemp -d) || return
    fi
    [[ -d $SB_WORK ]] || { fail '临时工作目录不存在'; return 1; }
    command -v jq >/dev/null 2>&1 || { fail '请先安装 jq'; return 1; }
}

read_text() {
    local answer
    if [[ $# -gt 1 ]]; then printf '%s [%s]：' "$1" "$2" >&2
    else printf '%s：' "$1" >&2; fi
    IFS= read -r answer || return 1
    printf '%s\n' "${answer:-${2-}}"
}

choose_index() {
    local prompt=$1 reply ordinal=1
    shift
    (( $# > 0 )) || { fail '没有可选择的项目'; return 1; }
    printf '\n%s\n' "$prompt" >&2
    for reply in "$@"; do
        printf '%d. %s\n' "$ordinal" "$reply" >&2
        ordinal=$((ordinal + 1))
    done
    while :; do
        printf '编号（q 取消）：' >&2
        IFS= read -r reply || return 1
        [[ $reply != q && $reply != Q ]] || return 1
        if [[ $reply =~ ^[1-9][0-9]*$ && ${#reply} -lt 8 ]] && ((reply <= $#)); then
            printf '%d\n' "$((reply - 1))"
            return 0
        fi
        printf '请输入列表中的编号。\n' >&2
    done
}

json_temp() { mktemp "$SB_WORK/value.XXXXXXXX"; }
new_id() { "$SB_CORE" generate uuid; }

free_port() {
    local port attempt listeners
    command -v ss >/dev/null 2>&1 || { fail '分配空闲端口需要 ss（iproute2）'; return 1; }
    listeners=$(ss -H -lntu) || return
    for ((attempt=0; attempt<100; attempt++)); do
        port=$(shuf -i 20000-59999 -n 1) || return
        if ! awk -v port="$port" '$5 ~ (":" port "$") {found=1} END {exit !found}' <<<"$listeners"; then
            printf '%s\n' "$port"
            return 0
        fi
    done
    fail '没有找到可用端口，请手动指定'
}

server_address() {
    local address
    if [[ -f $SB_META ]]; then
        address=$(jq -er '.server | select(type == "string" and length > 0)' "$SB_META") || return
    elif command -v curl >/dev/null 2>&1; then
        address=$(curl --fail --silent --show-error --max-time 10 https://api64.ipify.org) || return
    elif command -v wget >/dev/null 2>&1; then
        address=$(wget -qO- --timeout=10 https://api64.ipify.org) || return
    else
        fail '未设置服务器地址，且缺少 curl/wget'
        return 1
    fi
    [[ -n $address && $address != *[[:space:]]* ]] || { fail '服务器地址无效'; return 1; }
    printf '%s\n' "$address"
}
