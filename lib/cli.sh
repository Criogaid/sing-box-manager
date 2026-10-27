#!/usr/bin/env bash
manager_help() {
    cat <<'HELP'
sing-box-manager — 本地管理工具

配置
  add [预设] [参数...]             创建入站；不指定则打开菜单
  add inbound [类型]              使用当前核心的完整字段表单
  change [名称] [字段] [值...]     修改入站
  change 名称 settings [字段 值]  完整字段菜单或单字段修改
  info [名称] [settings]          查看连接信息或全部实际字段
  url [名称] / qr [名称]          分享链接或本机二维码
  del [名称] / ddel 名称...       删除入站
  port/path/host/passwd/id/key/sni/method/username/web 名称 值
  new 名称 [预设 参数...]         更换协议
  full 名称 [参数...]             重设配置参数

DNS 与日志
  dns add [类型]                  添加 DNS 服务器
  dns change [标识] [字段 值]     修改 DNS 服务器
  dns del [标识] / dns info [标识]
  dns settings [字段 值]          主配置的 DNS 字段
  dns set 地址 / dns none         默认解析器
  log [--no-follow|级别|del]       日志查看、级别设置或清空文件

维护
  start/stop/restart/status [caddy]
  update core|caddy [版本]        官方核心或 Caddy 更新
  update sh [本地目录]            安装本地管理器源码
  install / reinstall / uninstall
  import                          从已有 Xray/V2Ray 脚本配置迁移
  fix [名称] / fix-all / fix-config.json / fix-caddyfile
  test                            检查完整核心配置
  bbr                             启用内核支持的 BBR

工具
  version / ip / pbk / get-port / ss2022
  gen [预设 参数...]              只生成配置，不写入
  no-auto-tls [预设 参数...]      创建时自行配置公网 TLS 前端
  bin 参数...                     调用原生核心；其他核心命令也直接透传

所有修改先检查候选配置，失败不写入。菜单输入 q 或 EOF 取消。
HELP
}

manager_menu() {
    local section item
    section=$(choose_index '管理操作' '入站配置' 'DNS 设置' '服务与日志' '更新与安装' '帮助与版本') || return
    case $section in
    0)
        item=$(choose_index '入站操作' '添加' '修改' '查看' '分享链接' '二维码' '删除') || return
        case $item in
        0) node_add ;; 1) node_change '' ;; 2) node_info '' ;;
        3) node_url '' ;; 4) node_qr '' ;; 5) node_delete '' ;;
        esac
        ;;
    1) dns_command ;;
    2)
        item=$(choose_index '服务与日志' '状态' '启动' '停止' '重启' '查看最近日志' '检查配置') || return
        case $item in
        0) host_service status ;; 1) host_service start ;; 2) host_service stop ;;
        3) host_service restart ;; 4) host_log --no-follow ;; 5) manager_main test ;;
        esac
        ;;
    3)
        item=$(choose_index '维护操作' '更新核心' '更新 Caddy' '更新管理器' '导入旧配置' '重装' '卸载') || return
        case $item in
        0) host_update core ;; 1) host_update caddy ;; 2) host_update sh ;;
        3) host_import ;; 4) host_reinstall ;; 5) host_uninstall ;;
        esac
        ;;
    4) manager_main version; manager_help ;;
    esac
}

manager_main() {
    local operation=${1:-menu} target
    (( $# == 0 )) || shift
    case $operation in
    menu|main) manager_menu ;;
    help|h|--help|-h) manager_help ;;
    version|v|--version)
        printf 'sing-box-manager %s\n' "$SB_VERSION"
        [[ ! -x $SB_CORE ]] || "$SB_CORE" version
        ;;
    add|a) node_add "$@" ;;
    change|c|config) node_change "$@" ;;
    del|d|rm) node_delete "$@" ;;
    ddel|dd)
        (( $# > 0 )) || { fail '请指定要删除的名称'; return 1; }
        for target in "$@"; do node_delete "$target" || return; done
        ;;
    info|i) node_info "$@" ;;
    url) node_url "$@" ;;
    qr) node_qr "$@" ;;
    port|path|host|key|sni|method|username|web|new|full)
        target=${1:-}
        (( $# == 0 )) || shift
        node_change "$target" "$operation" "$@"
        ;;
    passwd|password|pass|id|uuid|ssm|ss-method|ss_method|publickey|privatekey|servername|servernames|proxy-site|dda|door-addr|door_addr|ddp|door-port|door_port)
        case $operation in
        passwd|password|pass) operation=passwd ;; id|uuid) operation=id ;;
        ssm|ss-method|ss_method) operation=method ;;
        publickey|privatekey) operation=key ;;
        servername|servernames) operation=sni ;; proxy-site) operation=web ;;
        dda|door-addr|door_addr) operation=door-addr ;;
        ddp|door-port|door_port) operation=door-port ;;
        esac
        target=${1:-}
        (( $# == 0 )) || shift
        node_change "$target" "$operation" "$@"
        ;;
    dns) dns_command "$@" ;;
    log) host_log "$@" ;;
    start|stop|restart|status|s|r)
        case $operation in s) operation=status ;; r) operation=restart ;; esac
        (( $# <= 1 )) || { fail '服务命令只接受可选组件名称'; return 1; }
        host_service "$operation" "${1:-sing-box}"
        ;;
    update|u) host_update "$@" ;;
    update.sh|U) host_update sh "$@" ;;
    install) host_install "$@" ;;
    reinstall) host_reinstall "$@" ;;
    uninstall|un) host_uninstall "$@" ;;
    import|in) host_import "$@" ;;
    fix) host_fix "$@" ;;
    fix-all) host_fix ;;
    fix-config.json) host_fix_base ;;
    fix-caddyfile) host_fix_frontend ;;
    test|t) host_check ;;
    debug) node_info "${1:-}" settings ;;
    ip) server_address ;;
    pbk) "$SB_CORE" generate reality-keypair ;;
    get-port) free_port ;;
    ss2022) openssl rand -base64 32 ;;
    bbr) host_bbr ;;
    gen) (SB_GENERATE=1; node_add "$@") ;;
    no-auto-tls) (SB_AUTO_FRONTEND=0; node_add "$@") ;;
    bin) "$SB_CORE" "$@" ;;
    *) "$SB_CORE" "$operation" "$@" ;;
    esac
}
