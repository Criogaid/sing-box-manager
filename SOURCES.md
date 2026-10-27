# 来源与许可范围

## 本项目的来源

本项目于 2026-10-26 从空目录建立。需求协调者曾维护既有管理器，但新实现工作会话只获得本目录的行为要求、模块接口和公开接口资料；没有向实现者提供旧管理器源码、测试、模板、补丁或 Git 历史。新测试使用自行编写的合成配置。真实安装的配置仅用于后续黑盒兼容验收。

这个过程用于减少继承旧实现的风险，不是法律鉴定，也不声称仅凭文件数量、函数名差异或文本相似度就能证明不构成派生作品。旧维护项目保持自己的许可，不通过本项目追溯改许可。

本项目的 MIT 授权范围是新写的管理器代码、测试和说明文件。使用方式是运行独立工具的公开命令行接口，不链接、复制或捆绑工具实现。

## 已查阅的公开规范

- [sing-box 配置与 check/format/merge](https://sing-box.sagernet.org/configuration/)：JSON 数据结构和配置处理命令。
- [Caddy 命令行](https://caddyserver.com/docs/command-line)：adapt 将 Caddyfile 转为配置 JSON，validate 会额外执行加载与供给检查。
- [JSON Schema 组合规则](https://json-schema.org/understanding-json-schema/reference/combining)：oneOf、anyOf、allOf 的规则语义。
- [MIT License](https://opensource.org/license/mit)：许可证标准文本与保留通知的要求。
- [GNU GPL FAQ：独立程序与聚合](https://www.gnu.org/licenses/gpl-faq.html#MereAggregation)：进程间普通命令行调用与合并程序的区别；不把外部工具的许可证改标为 MIT。
- [GNU GPL FAQ：代码翻译](https://www.gnu.org/licenses/gpl-faq.html#TranslateCode)：把现有受保护代码翻译或表面改写，不会自动解除原许可。

实际核心导出的 schema 在运行时读取，未纳入本项目分发内容。接口定义、字段名和命令名为互操作所必需，不宣称对第三方协议或名称拥有权利。

## 外部依赖

Bash、jq、sing-box、Caddy、OpenSSL、curl、tar、iproute2、qrencode 均单独安装，各自许可证继续有效。发布本管理器时不附带这些工具的代码或二进制；如另行打包工具，打包者需分别满足对应许可。

## 模块实现者补充的接口资料

- [JSON Schema 对象](https://json-schema.org/understanding-json-schema/reference/object)与[引用结构](https://json-schema.org/understanding-json-schema/structuring)：对象、字典、本地引用与递归。
- sing-box 入站文档：[Shadowsocks](https://sing-box.sagernet.org/configuration/inbound/shadowsocks/)、[ShadowTLS](https://sing-box.sagernet.org/configuration/inbound/shadowtls/)、[AnyTLS](https://sing-box.sagernet.org/configuration/inbound/anytls/)、[TUIC](https://sing-box.sagernet.org/configuration/inbound/tuic/)、[Hysteria2](https://sing-box.sagernet.org/configuration/inbound/hysteria2/)。
- sing-box [传输](https://sing-box.sagernet.org/configuration/shared/v2ray-transport/)、[TLS](https://sing-box.sagernet.org/configuration/shared/tls/)、[证书提供者](https://sing-box.sagernet.org/configuration/shared/certificate-provider/)及[迁移说明](https://sing-box.sagernet.org/migration/)。
- 分享格式：[SIP002](https://shadowsocks.org/doc/sip002.html)、[VMess/VLESS 格式讨论](https://github.com/XTLS/Xray-core/discussions/716)、[Hysteria2 URI](https://v2.hysteria.network/docs/developers/URI-Scheme/)、[AnyTLS URI 文档](https://raw.githubusercontent.com/anytls/anytls-go/main/docs/uri_scheme.md)。既有客户端所需的 SS、Socks、VMess 和 ShadowTLS 线格式同时作为行为契约提供。
- Xray [入站](https://xtls.github.io/config/inbound.html)、[传输](https://xtls.github.io/config/transport.html)、[TLS](https://xtls.github.io/config/transports/tls.html)、[Reality](https://xtls.github.io/config/transports/reality.html)、[HTTPUpgrade](https://xtls.github.io/config/transports/httpupgrade.html)及 V2Fly [H2](https://www.v2fly.org/config/transport/h2.html)：导入字段映射。读取的是格式文档，不是实现源码。
- GitHub 官方 [sing-box 发行元数据](https://api.github.com/repos/SagerNet/sing-box/releases/latest)与 [Caddy 发行元数据](https://api.github.com/repos/caddyserver/caddy/releases/latest)：发行资产命名、URL 和摘要字段；未读取仓库实现源码。
- Caddyfile [语法与概念](https://caddyserver.com/docs/caddyfile/concepts)、[import](https://caddyserver.com/docs/caddyfile/directives/import)、[reverse_proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)：路由定位、保留自定义指令及候选预检。
- sing-box DNS [UDP](https://sing-box.sagernet.org/configuration/dns/server/udp/)、[TLS](https://sing-box.sagernet.org/configuration/dns/server/tls/)、[HTTPS](https://sing-box.sagernet.org/configuration/dns/server/https/)：解析器地址的语义转换。
- 测试曾使用官方发行的 sing-box 1.14.4 与 Caddy 可执行程序，并读取其 `check/merge --help`。工具本身未纳入源码仓库。
