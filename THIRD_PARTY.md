# Third-party notes

本项目没有复制下列项目的生成代码或业务代码，但在接口兼容性调研、字段映射和联调时参考或调用了它们。

## aiotieba

- Repository: https://github.com/Starry-OvO/aiotieba
- Revision inspected: `bae68256fd250d5178e1447899ffa155c77eda38`
- License: The Unlicense
- Usage: 贴吧移动端 protobuf endpoint、表单签名、BDUSS 校验和已关注贴吧字段的互操作性参考。当前 Go wire codec、会话存储和 HTTP 实现为本项目独立实现。

贴吧全站热榜直接读取百度贴吧公开的 `https://tieba.baidu.com/hottopic/browse/topicList` 响应，没有引入额外第三方库。

贴吧扫码登录打开百度官方 `https://passport.baidu.com/v2/?login` 页面，并通过 Chromium 的临时会话取得登录结果；不模拟或收集账号密码。

## xiaohongshu-mcp

- Repository: https://github.com/xpzouying/xiaohongshu-mcp
- Revision inspected: `84511f19acccd7eea36ecce2e0e413eda449aa76`
- License: Apache License 2.0
- Usage: 安装脚本固定并构建该版本；`mixsocial` 自动把它作为受管子进程启动，仅调用其本地 HTTP API。项目保留了一份 Apache-2.0 的 `login.go` 构建补丁，将不稳定的整页 `WaitLoad` 改为等待登录二维码元素；其余业务实现仍直接使用该固定上游版本。

依赖库的具体版本由 `go.mod` 和 `go.sum` 记录。

## QR 与浏览器库

- `github.com/go-rod/rod`（MIT）：驱动内置 Chromium 完成百度官方扫码登录。
- `github.com/liyue201/goqr`（MIT）：从 sidecar 返回的二维码图片中恢复原始载荷。
- `github.com/makiuchi-d/gozxing`（MIT / Apache-2.0）：兼容无标准留白图片的备用纯 Go 二维码解码器。
- `github.com/skip2/go-qrcode`（MIT）：按二维码模块边界和标准留白区重新编码，供终端稳定显示。
