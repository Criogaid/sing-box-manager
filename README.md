# sing-box-manager

一个独立编写的 Bash 管理器，使用 [MIT 许可证](LICENSE)。通过 sing-box 和 Caddy 的命令行接口管理配置，不包含这些工具的源码或二进制。

## 使用

需要 Linux、Bash 4.3 以上、jq、OpenSSL、curl、tar、iproute2 和 qrencode。已有核心默认位于 `/etc/sing-box/bin/sing-box`，读取 `config.json` 和 `conf/*.json`；完整字段菜单要求核心支持 `schema` 命令。

```bash
bash sb                         # 交互菜单
bash sb info                    # 选择并查看入站
bash sb url TAG                  # 输出分享链接
bash sb qr TAG                   # 本机生成二维码
bash sb add inbound              # 选择当前核心支持的类型
bash sb change TAG settings      # 编辑实际字段
bash sb change TAG settings tcp_fast_open on
bash sb dns add
bash sb dns change DNS_TAG
bash sb dns info
bash sb log --no-follow
bash sb help
```

字段菜单支持对象、列表、字典、开关和配置形式切换，不要求输入 JSON。修改先检查完整候选配置，再写入并应用。未修改的配置字段和文件布局保留。

已关联 Caddy 的入站通过实际后端端口和路径定位前端。`port TAG N` 修改公网端口，`change TAG settings listen_port N` 修改后端端口并同步反代；自定义站点附加内容保留。存在歧义时报告错误，不猜测目标。

## 安装

```bash
# 接管已有运行环境，只安装本项目及命令链接
bash install.sh --adopt

# 全新环境安装；核心从官方发行包获取
bash install.sh --core-version 1.14.4 SERVER_ADDRESS

# 后续更新管理器
sb update sh /path/to/this/project
```

管理器安装到 `/etc/sing-box/manager`，命令链接为 `sb` 和 `sing-box`。旧管理器文件不进入本项目的发布包。接管不重建现有配置、不修改服务单元、不重启服务。

## 隔离运行与测试

可用 `SB_ROOT`、`SB_CORE`、`SB_CADDY_ROOT`、`SB_CADDY` 指定临时路径。`SB_SERVICE_MANAGER=none` 用于离线检查或测试，禁用服务操作；配置检查仍执行。

```bash
bash tests/run.sh
TEST_CORE=/path/to/sing-box TEST_CADDY=/path/to/caddy bash tests/run.sh
```

测试从功能要求重新编写，默认使用临时目录和命令替身。实际核心/Caddy 集成也只写临时配置。不要把未通过接管验收的版本直接替换生产脚本。

## 实现与许可边界

本项目从空目录开始，新的实现会话只接收[行为要求](REQUIREMENTS.md)、[模块接口](CONTRACTS.md)和公开接口资料，没有导入旧管理器的源码、测试或 Git 历史。协调者曾维护旧版本；这里记录的是独立重写过程，不宣称经过法律意义上的洁净室认证，也不以“代码相似度低”作为许可结论。

MIT 仅覆盖本项目自行编写的管理器、文档和测试。sing-box、Caddy、jq、OpenSSL、qrencode 等是单独安装、通过进程调用的外部工具，它们各自的许可证继续有效。公开资料和实现来源记录见 [SOURCES.md](SOURCES.md)。

## 支持边界与验证

本版已经在 Linux、jq 1.6、sing-box 1.14.4 和真实 Caddy 上通过配置与安装集成测试。覆盖入站和 DNS 修改、引用保护、Caddy 预检拒绝、共享端口隔离、相对证书路径、安装链接、快捷预设及导入失败保留来源。服务启停和系统安装流程使用替身测试；不会为测试修改正在运行的服务。

Caddy 功能需要预先安装 Caddy 及其系统服务。管理器保留现有 Caddyfile 布局，支持 WS、HTTP/2 和 HTTPUpgrade 后端；复杂或歧义反代布局会拒绝自动编辑。未安装 Caddy 时仍可管理直连入站。

旧配置导入限受支持的入站片段，不转换全量路由。不能无损映射的字段、多证书或复杂 Reality 允许列表会明确拒绝，原文件保留。`uninstall` 只移除本管理器和命令链接，核心、配置和服务保留；`reinstall` 会明确确认后重建运行配置。

首次安装的自动依赖引导支持 Debian/Ubuntu 和 Alpine；其他 Linux 需要自行准备依赖。字段菜单类型随实际核心编译功能变化，不代表每种协议都经过公网客户端实连验证。
