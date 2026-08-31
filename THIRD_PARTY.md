# Third-party notes

本项目没有复制下列项目的生成代码或业务代码，但在接口兼容性调研、字段映射和联调时参考或调用了它们。

## aiotieba

- Repository: https://github.com/Starry-OvO/aiotieba
- Revision inspected: `bae68256fd250d5178e1447899ffa155c77eda38`
- License: The Unlicense
- Usage: 贴吧移动端 protobuf endpoint、表单签名、BDUSS 校验和已关注贴吧字段的互操作性参考。当前 Go wire codec、会话存储和 HTTP 实现为本项目独立实现。

贴吧全站热榜直接读取百度贴吧公开的 `https://tieba.baidu.com/hottopic/browse/topicList` 响应，没有引入额外第三方库。

贴吧扫码登录打开百度官方 `https://passport.baidu.com/v2/?login` 页面，并通过 Chromium 的临时会话取得登录结果；不模拟或收集账号密码。

## TiebaLite

- Repository: https://github.com/min09577/TiebaLite
- Branch and revision inspected: `4.0-dev` at `9ad89c3dfe094aaf6ba0262aad2d048d424a6446`
- License: GPL-3.0
- Usage: 移动端信息架构、官方个性推荐、搜索/主题/楼中楼分页行为，以及百度贴吧公开 Hybrid JSON 和 protobuf 路由/字段的兼容性调研。当前 Flutter 组件、Go HTTP 客户端与 wire/JSON 映射均为本项目独立实现；没有复制或链接 TiebaLite 的 GPL 业务代码或生成代码。

贴吧全站主题搜索读取百度贴吧公开的 `https://tieba.baidu.com/mo/q/search/thread` 响应，不发送 BDUSS 或 STOKEN。

贴吧推荐频道读取移动端 protobuf 路由 `https://tiebac.baidu.com/c/f/excellent/personalized?cmd=309264`；未配置固定吧时不再用关注吧聚合冒充推荐流。

## xiaohongshu-mcp

- Repository: https://github.com/xpzouying/xiaohongshu-mcp
- Revision integrated by the installer: `84511f19acccd7eea36ecce2e0e413eda449aa76`
- Additional revision inspected for Android interoperability: `6fb866a7db4e3dcce8dc00a0dde07370f3b12946`
- License: Apache License 2.0
- Usage: 安装脚本固定并构建较早版本；`mixsocial` 自动把它作为受管子进程启动，仅调用其本地 HTTP API。项目保留了一份 Apache-2.0 的 `login.go` 构建补丁，将不稳定的整页 `WaitLoad` 改为等待登录二维码元素。Android WebView 另外参考了新版中的 SSR 状态路径、PC 搜索筛选文案、评论滚动容器和用户主页分类行为；Dart 数据映射与 UI 为本项目独立实现。

依赖库的具体版本由 `go.mod` 和 `go.sum` 记录。

## QR 与浏览器库

- `github.com/go-rod/rod`（MIT）：驱动内置 Chromium 完成百度官方扫码登录。
- `github.com/liyue201/goqr`（MIT）：从 sidecar 返回的二维码图片中恢复原始载荷。
- `github.com/makiuchi-d/gozxing`（MIT / Apache-2.0）：兼容无标准留白图片的备用纯 Go 二维码解码器。
- `github.com/skip2/go-qrcode`（MIT）：按二维码模块边界和标准留白区重新编码，供终端稳定显示。
- `github.com/charmbracelet/x/ansi`（MIT）：编码 Kitty、iTerm2、Sixel 控制序列及终端复用器 passthrough。
- `golang.org/x/image`（BSD-3-Clause）：解码 WebP，并在原生终端图片编码前做高质量缩放。
