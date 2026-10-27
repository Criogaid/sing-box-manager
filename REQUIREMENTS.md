# 独立管理器行为要求

本文件是功能需求，不是旧程序的实现设计。新项目由空目录开始编写，不能用重命名、换语言、改缩进或结构改造旧代码的方式完成。

## 环境与数据

- Linux，Bash 4.3+、jq、OpenSSL、qrencode；核心和 Caddy 作为独立进程调用。当前验收核心 1.14.4。
- 已有主配置 `/etc/sing-box/config.json`、片段 `/etc/sing-box/conf/*.json`、核心 `/etc/sing-box/bin/sing-box`、服务器地址 `/etc/sing-box/script.json` 的 `server`。已有核心配置不能改布局或被整份重建；未修改的键和值保持。
- Caddyfile `/etc/caddy/Caddyfile`，站点 `/etc/caddy/sing-box/*.conf`，自定义 `.conf.add`，额外 `/etc/caddy/sites/*.conf`。常见布局单一站点块+handle路径+reverse_proxy，支持127.0.0.1/localhost与h2c后端。地址来自配置，不凭文件名猜测。存在歧义拒绝修改。
- 所有写入先用实际核心合并检查完整候选；相关 Caddy 也先适配检查。检查失败不改活动文件。检查通过立即提交并应用，不创建事务或回滚服务。
- 完整类型与字段来自运行核心的 schema，支持嵌套对象/列表/字典、引用、联合类型、条件分支、可选字段省略。实际校验交给核心。不把生成的 schema 放入代码仓库。

## 用户功能

- 无参数进入中文交互菜单，包含添加、更改、查看、删除、服务、更新、日志/DNS、帮助。允许界面布局、名称和内部结构重新设计。
- `add inbound [type]`、`change TAG settings [field value]`、`info TAG settings`：完整入站表单及语义字段操作。添加时能在同一候选文档中设置相互关联的入站和 DNS，整体检查后应用。
- `dns add [type]`、`dns change [tag] [field value]`、`dns del [tag]`、`dns info [tag]`、`dns settings [field value]`。服务器按 tag 找到源文件；settings 编辑主配置 DNS。保留 DNS 规则、引用和其他服务器。
- 原快捷命令保持有用的兼容行为：`add [preset] [args...]`、`new TAG ...`、`full TAG ...`；预设提供 VLESS Reality、VMess TCP/WS/HTTP/H2/HTTPUpgrade/QUIC、VLESS WS/H2/HTTPUpgrade、Trojan及WS/H2/HTTPUpgrade、SS、Socks、Direct、TUIC、Hysteria2、AnyTLS、ShadowTLS组合。完整类型列表不能由预设充当。
- `port TAG N|auto`：有Caddy时改公网端口，否则改入站端口。settings listen_port始终改后端并联动现有Caddy。`path`同步反代；`host`改公网域名保留后端及自定义站点内容；`web`改伪装反代；`passwd/pass/password`、`id/uuid`、`key`、`sni`、`method`、`username`、`door-addr/door-port`修改实际字段，auto生成符合字段要求的随机值。
- `del TAG`删除一个入站；专属ShadowTLS内层可以一起删除，但共享内层或其他片段不得误删。引用残留必须由核心检查阻止。支持标签优先、文件名、旧文件名正则和列表选择。同文件多个入站必须区分。
- `info/url/qr`读取真实配置。有效URL涵盖VMess、VLESS Reality、Trojan TCP/WS、SS、Socks、TUIC、Hysteria2、AnyTLS及ShadowTLS外内组合。无已知分享格式的协议只显示字段，不伪造链接。URL编码必须保留特殊字符。真实Reality私钥推导公钥，不能读取过期公钥缓存。展示私钥时隐藏值。TLS/ACME/SNI/flow/short_id/ws early-data都取实际值。Caddy前端的域名/公网端口用于连接信息。
- `log [debug|info|warn|error|del|--no-follow]`：使用实际配置文件日志或journal，修改级别保留文件路径。删除日志只清空文件，不删配置。
- `start/stop/restart/status [caddy]`、`test`，systemd与OpenRC；重启前验证。`update core [version]`/`update caddy [version]`用官方发行包；`update sh [local-directory]`、`install`与`reinstall`用本地独立源码，不指向未知GitHub地址。
- `import`/`in`保持为旧Xray/V2Ray脚本配置转换操作。逐个检查转换成功再删除对应来源文件；不新增任意原生JSON导入接口。
- 基础实用功能：version/ip/pbk/get-port/ss2022/bin核心透传、fix/fix-all/fix-config.json/fix-caddyfile、BBR、gen（仅输出生成结果、不写入）和no-auto-tls。缺少必要值时提问，EOF或取消不得修改文件。
- `a/c/config/d/rm/i/u/U/un/r/h/v`等别名解析于入口，不在各层维护副本。未知核心命令透传以保留扩展能力。

## 发行与验证

- 新的MIT许可证只覆盖新管理器源码和原创测试；不改独立工具的许可证，不捆绑旧代码或旧历史。来源说明如实记录工作方法，不能声称通过相似度阈值即可保证法律独立。
- 单元与集成测试全部从需求重新编写。使用临时文件及服务替身，真实核心/Caddy执行隔离配置检查。提供安装及非安装运行说明。
- 旧七台运行版本不先替换；待23个现有节点只读兼容验证、写入行为回归、Caddy一致性和新安装验证完成后才允许切换。公网连接凭据不得输出到公开报告。
