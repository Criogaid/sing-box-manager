#!/usr/bin/env bash
set -euo pipefail

# 自动补依赖支持 Debian/Ubuntu（apt-get）和 Alpine（apk）；其他 Linux 需预装这些工具。
_installer_dependencies() {
    local tool missing=0
    for tool in jq openssl qrencode curl tar ss; do
        command -v "$tool" >/dev/null 2>&1 || missing=1
    done
    [[ $missing == 1 ]] || return 0
    [[ $EUID == 0 ]] || { printf '缺少安装依赖，需要 root 安装 jq openssl qrencode curl tar iproute2\n' >&2; return 1; }
    local ID='' ID_LIKE=''
    [[ ! -f /etc/os-release ]] || source /etc/os-release
    case " $ID $ID_LIKE " in
        *' debian '*|*' ubuntu '*) apt-get update && apt-get install -y jq openssl qrencode curl tar iproute2 ca-certificates;;
        *' alpine '*) apk add --no-cache jq openssl qrencode curl tar iproute2-ss ca-certificates;;
        *) printf '此系统需预装 jq openssl qrencode curl tar iproute2，再执行安装\n' >&2; return 1;;
    esac
    for tool in jq openssl qrencode curl tar ss; do
        command -v "$tool" >/dev/null 2>&1 || { printf '安装后仍缺少依赖：%s\n' "$tool" >&2; return 1; }
    done
}

installer_main() {
    local source adopt=0 reinstall=0 core_file='' core_version='' server='' proxy=''
    source=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    while (($#)); do
        case $1 in
            --adopt) adopt=1; shift;;
            --reinstall) reinstall=1; shift;;
            --local-install|-l) source=$PWD; shift;;
            --core-file|-f|--core-version|-v|--proxy|-p)
                (($# >= 2)) || { printf '选项缺少值：%s\n' "$1" >&2; return 1; }
                case $1 in --core-file|-f) core_file=$2;; --core-version|-v) core_version=$2;; --proxy|-p) proxy=$2;; esac
                shift 2;;
            -*) printf '未知安装选项：%s\n' "$1" >&2; return 1;;
            *) [[ -z $server ]] || { printf '只能指定一个服务器地址\n' >&2; return 1; }; server=$1; shift;;
        esac
    done
    [[ $adopt == 0 || $reinstall == 0 ]] || { printf '接管与重装不能同时使用\n' >&2; return 1; }
    [[ ! -L $source/lib ]] || { printf '源码模块目录不能是符号链接\n' >&2; return 1; }
    [[ -f $source/lib/common.sh && -f $source/lib/host.sh ]] || { printf '缺少独立源码模块\n' >&2; return 1; }
    export SB_PROJECT=$source
    # 只加载模块，绝不 source 入口以免触发命令分派。
    source "$source/lib/common.sh"
    source "$source/lib/host.sh"
    if [[ $adopt == 0 ]]; then
        [[ $reinstall == 0 ]] || _host_confirm '重新安装将重建基础配置、片段目录和核心。'
        if [[ -z $server ]]; then server=$(read_text '请输入服务器地址'); fi
        [[ -n $server && $server != *[[:space:]]* ]] || { fail '服务器地址不能为空或包含空白'; return 1; }
        _installer_dependencies
    fi
    SB_WORK=$(mktemp -d)
    trap 'rm -rf -- "$SB_WORK"' EXIT
    runtime_init
    export SB_ROOT SB_CORE SB_MAIN SB_PARTS SB_META SB_CADDY_ROOT SB_CADDY SB_CADDYFILE SB_SITES SB_SERVICE_MANAGER
    if [[ $adopt == 0 && $SB_SERVICE_MANAGER != none ]]; then
        # 生成的单元使用绝对路径，在写入前拒绝需要 shell 或 systemd 转义的路径。
        [[ $SB_ROOT =~ ^/[A-Za-z0-9_./-]+$ && $SB_CORE =~ ^/[A-Za-z0-9_./-]+$ ]] || { fail '服务路径含不支持的字符'; return 1; }
    fi
    local bin=${SB_BIN_DIR:-/usr/local/bin} service_dir managed candidate stage main_candidate
    managed="$SB_ROOT/manager"
    [[ ! -L $managed && ! -L $managed/lib ]] || { fail '安装目标不能是符号链接'; return 1; }
    stage=$(mktemp -d "$SB_WORK/manager.XXXXXX")
    _host_copy_source "$source" "$stage"
    printf '%s\n' 'MIT independent manager' >"$stage/.independent-manager"
    local link
    for link in sb sing-box; do
        if [[ -e $bin/$link || -L $bin/$link ]]; then
            [[ -L $bin/$link ]] || { fail "命令路径已被普通文件占用：$bin/$link"; return 1; }
        fi
    done
    if [[ $adopt == 1 ]]; then
        [[ -f $SB_MAIN && -x $SB_CORE ]] || { fail '接管需要已有核心与主配置'; return 1; }
        if [[ -n $server ]]; then
            [[ -f $SB_META ]] && jq -e --arg server "$server" '.server == $server' "$SB_META" >/dev/null || { fail '接管地址与现有元数据不一致，已拒绝接管'; return 1; }
        fi
        host_check
        # 接管不写 server、不重建配置、不写服务单元、不调用服务管理器。
    else
        if [[ $reinstall == 0 && ( -e $SB_MAIN || -e $SB_CORE || -d $SB_PARTS ) ]]; then
            fail '检测到已有运行环境，请使用 --adopt 或明确执行重装'; return 1
        fi
        candidate=$(json_temp)
        if [[ -n $core_file ]]; then
            [[ -f $core_file ]] || { fail '本地核心文件不存在'; return 1; }
            case $core_file in
                *.tar.gz|*.tgz)
                    local member listing members=0
                    listing=$(tar -tzf "$core_file")
                    while IFS= read -r member; do
                        if [[ $member == sing-box || $member == */sing-box ]]; then
                            members=$((members+1))
                            tar -xzf "$core_file" -O "$member" >"$candidate"
                        fi
                    done <<<"$listing"
                    [[ $members == 1 ]] || { fail '核心压缩包需要唯一的 sing-box 可执行文件'; return 1; };;
                *) [[ -x $core_file ]] || { fail '请提供 .tar.gz 包或核心可执行文件'; return 1; }; cp -- "$core_file" "$candidate";;
            esac
        else
            SB_DOWNLOAD_PROXY=$proxy _host_release core "$core_version" "$candidate"
        fi
        chmod 755 "$candidate"
        "$candidate" version >/dev/null
        main_candidate=$(json_temp)
        jq -n '{log:{level:"info"},dns:{servers:[]},inbounds:[],outbounds:[{type:"direct",tag:"direct"}]}' >"$main_candidate"
        "$candidate" check -c "$main_candidate"
        mkdir -p "$SB_ROOT" "$(dirname "$SB_CORE")"
        local binary_stage
        binary_stage=$(mktemp "${SB_CORE}.new.XXXXXX")
        install -m 755 "$candidate" "$binary_stage"
        mv -f -- "$binary_stage" "$SB_CORE"
        [[ $reinstall == 0 || ! -d $SB_PARTS ]] || rm -rf -- "$SB_PARTS"
        mkdir -p "$SB_PARTS"
        install -m 600 "$main_candidate" "$SB_MAIN"
        jq -n --arg server "$server" '{server:$server}' >"$SB_WORK/meta.json"
        install -m 600 "$SB_WORK/meta.json" "$SB_META"
        case $SB_SERVICE_MANAGER in
            systemd)
                service_dir=${SB_SYSTEMD_DIR:-/etc/systemd/system}
                mkdir -p "$service_dir"
                cat >"$service_dir/sing-box.service" <<UNIT
[Unit]
Description=sing-box independent core
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$SB_ROOT
ExecStart="$SB_CORE" run -c "$SB_MAIN" -C "$SB_PARTS"
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
                systemctl daemon-reload;;
            openrc)
                service_dir=${SB_OPENRC_DIR:-/etc/init.d}
                mkdir -p "$service_dir"
                cat >"$service_dir/sing-box" <<UNIT
#!/sbin/openrc-run
description="sing-box independent core"
command="$SB_CORE"
command_args="run -c $SB_MAIN -C $SB_PARTS"
command_background=true
pidfile="/run/sing-box.pid"
directory="$SB_ROOT"
depend() {
    need net
    after firewall
}
UNIT
                chmod 755 "$service_dir/sing-box";;
            none) ;;
            *) fail '无法识别服务管理器'; return 1;;
        esac
    fi
    mkdir -p "$managed/lib" "$bin"
    # 来源已完整暂存，支持从已安装管理器更新自身。
    _host_copy_source "$stage" "$managed"
    install -m 600 "$stage/.independent-manager" "$managed/.independent-manager"
    ln -sfn -- "$managed/sb" "$bin/sb"
    ln -sfn -- "$managed/sb" "$bin/sing-box"
    if [[ $adopt == 0 ]]; then
        host_service enable sing-box
        host_service restart sing-box
    fi
    printf '管理器已安装：%s\n' "$managed" >&2
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then installer_main "$@"; fi
