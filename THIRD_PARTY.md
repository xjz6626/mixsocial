# Third-party notes

本文件记录项目在接口兼容性调研、字段映射、联调或代码移植中参考、调用及改编的第三方项目。每节会明确实际使用方式。

## JimChengLin/zhihu-tui

- Repository: https://github.com/JimChengLin/zhihu-tui
- Revision adapted: `61f2fdf3d3a7aaa6a1f53a6a2a4ac59731993ab0`（2026-09-22）
- License: Apache License 2.0（全文见 `LICENSES/Apache-2.0.txt`）
- Usage: 知乎纯 Go HTTP 客户端、浏览器请求头、有限读取重试、扫码登录流程、Cookie 校验、推荐/关注/热榜/搜索/详情/评论及互动端点的基础实现来自或参考该项目。`internal/source/zhihu` 已按 mixsocial 的统一领域模型、并发方式、会话位置和安全边界重构；没有移植上游 TUI、发布、删除、通知或图片上传功能。上游 `NOTICE` 中对 `BAIGUANGMEI/zhihu-cli` 的 API 研究归属已保留在本仓库根目录的 `NOTICE`。

知乎适配器调用的是非官方网页/客户端接口，与知乎无隶属关系。接口可能变化或触发风控；请控制频率，只访问自己有权访问的数据，并遵守知乎条款和当地法律。

## aiotieba

- Repository: https://github.com/Starry-OvO/aiotieba
- Revision inspected: `6a32de113ba35dd4da2ec0e76540e79678f9b8d8`
- License: The Unlicense
- Usage: 贴吧移动端 protobuf endpoint、表单签名、BDUSS 校验和已关注贴吧字段的互操作性参考，并核对点赞写接口的风险说明。当前 Go wire codec、会话存储和 HTTP 实现为本项目独立实现；Android 贴吧写操作交给百度官方可见页面，不调用该私有写接口。

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

## ReaJason/xhs

- Repository: https://github.com/ReaJason/xhs
- Source inspected: [`xhs/core.py`](https://github.com/ReaJason/xhs/blob/master/xhs/core.py), `master`，2026-09-08 核对。
- License: [MIT](https://github.com/ReaJason/xhs/blob/master/LICENSE)
- Usage: 核对网页点赞/取消赞、收藏/取消收藏、评论/回复、关注/取消关注、评论点赞/取消赞的路径、笔记 ID、用户 ID 与评论目标字段，以及自己的资料/笔记/收藏/点赞列表接口的可行性。Android 的页面请求观察器为本项目独立实现；只确认本次互动对应的 fetch/XHR 服务端结果，并阻止错误目标、反向操作及重复提交，请求及签名仍由登录网页生成。自己的主页入口从网页账号状态读取身份，并复用已有网页分类，不直接调用上述资料接口。没有引入该 Python 客户端或复制其签名实现。

## QR 与浏览器库

- `github.com/go-rod/rod`（MIT）：驱动内置 Chromium 完成百度官方扫码登录。
- `github.com/liyue201/goqr`（MIT）：从 sidecar 返回的二维码图片中恢复原始载荷。
- `github.com/makiuchi-d/gozxing`（MIT / Apache-2.0）：兼容无标准留白图片的备用纯 Go 二维码解码器。
- `github.com/skip2/go-qrcode`（MIT）：按二维码模块边界和标准留白区重新编码，供终端稳定显示。
- `github.com/charmbracelet/x/ansi`（MIT）：编码 Kitty、iTerm2、Sixel 控制序列及终端复用器 passthrough。
- `golang.org/x/image`（BSD-3-Clause）：解码 WebP，并在原生终端图片编码前做高质量缩放。
