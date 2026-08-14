# mixsocial

把百度贴吧和小红书放进同一个终端信息流的 Go TUI。支持推荐、热榜、关注、搜索、详情和评论查看；小红书还支持点赞、收藏、评论与回复。**不提供发布入口，公共接口里也没有发布方法。**

## 当前实现

- 统一模型：条目、作者、媒体、统计、详情和评论。
- 混合信息流：并发读取各来源，按来源轮流合并；单个来源失败不会拖垮另一来源。
- 三个首页频道：按 `1` / `2` / `3` 切换推荐、热榜和关注，仍可用 `Tab` 过滤平台。
- 百度贴吧：直接用 Go 编解码移动端 protobuf；支持全站热议榜、按吧主题、主题楼层、百度 App 扫码登录、BDUSS 备用登录和已关注贴吧内容，无 Python 运行时。
- 小红书：安装脚本会把固定版本的 `xiaohongshu-mcp` 一并装到 `mixsocial` 旁边；`mixsocial` 启动和回收子进程，用户无需手动运行 sidecar。可在 TUI 内扫码登录，Cookie 和网页签名仍由成熟的上游实现管理。
- 所有会改变账号状态的操作都要求在 TUI 中再次按 `y` 确认。

这是非官方客户端。站点接口和风控可能随时改变；请控制频率，只访问自己有权访问的数据，并遵守平台条款和当地法律。

## 快速体验

需要 Go 1.24 或更新版本。

一键编译并安装到当前用户的 `~/.local/bin`：

```bash
./install.sh
mixsocial --demo
```

自定义安装目录：

```bash
./install.sh --bin-dir /path/to/bin
```

脚本会同时安装 `mixsocial` 和它管理的 `xiaohongshu-mcp`，但日常只需运行 `mixsocial`。如果 `~/.local/bin` 尚未在 `PATH` 中，脚本会打印需要加入 shell 配置的命令。

安装阶段默认同时下载并校验约 140–190 MB 的定制 Chromium，因此安装完成后的首次启动不再联网下载。CI、离线打包或只想先装二进制时可跳过：

```bash
./install.sh --skip-browser
```

也可以不安装，直接从源码运行：

```bash
go run ./cmd/mixsocial --demo
```

真实贴吧的公开读取和热议榜不要求登录。`--tieba-forums` 配置推荐频道要混合的吧；未配置但已登录时会使用已关注贴吧。搜索时，贴吧来源会把搜索词解释为吧名。

```bash
go run ./cmd/mixsocial \
  --xhs=false \
  --tieba-forums=golang,linux
```

## 登录

`L` 登录当前来源：先用 `Tab` 切到贴吧或小红书；在“全部”来源中，也可以先选中该平台的一条内容再按 `L`。

### 贴吧

推荐直接按大写 `L`：mixsocial 会用内置 Chromium 打开百度官方登录页，把二维码显示在终端中；使用百度 App 扫描并确认即可。扫码页面和状态检查共用同一个临时浏览器，成功后提取会话、通过贴吧客户端接口校验，再自动关闭浏览器。mixsocial 不接收百度账号密码。

若扫码受风控或使用 `--skip-browser` 安装，可按大写 `B` 导入已有网页会话：

1. 在浏览器中正常登录 `https://tieba.baidu.com`。
2. 打开开发者工具的 Application / Storage → Cookies → `tieba.baidu.com`，复制 `BDUSS` 的值。
3. TUI 中用 `Tab` 切到“贴吧”，按大写 `B`，粘贴后回车。也可粘贴 `BDUSS=...; STOKEN=...` 形式的 Cookie。

导入内容在终端里会被遮罩。扫码或导入成功后，会话保存到用户配置目录下的 `mixsocial/tieba-session.json`，文件权限为 `0600`、目录权限为 `0700`。BDUSS 等同登录凭据，请勿发给他人，也不要放到命令行参数、shell 历史或项目文件中。

### 小红书

安装后启动 TUI，切到“小红书”并按大写 `L`，用小红书 App 扫描终端内的二维码：

```bash
mixsocial --tieba-forums=golang,linux
```

`mixsocial` 会自动查找同目录或 `PATH` 中的 `xiaohongshu-mcp`，在 `127.0.0.1:18060` 启动它，并在退出时连同浏览器子进程一起回收。Chromium 默认已由安装脚本放入上游浏览器缓存；只有使用 `--skip-browser` 安装时才会在首次启动下载。扫码等待期间 mixsocial 只监测 sidecar 写入的会话文件，不会反复启动浏览器检查状态；首次登录前也不会先启动推荐流浏览器。二维码会先解码再按完整模块和留白区重绘，以避免终端缩放导致手机无法识别。较矮的终端自动使用紧凑模式，放大窗口后会切回标准半块模式。会话和日志默认保存在用户配置目录的 `mixsocial` 子目录中。

若已有自己管理的 sidecar，可关闭进程托管：

```bash
MIXSOCIAL_XHS_ENDPOINT=http://127.0.0.1:18060 \
MIXSOCIAL_XHS_TOKEN=可选的Bearer令牌 \
mixsocial --xhs-managed=false
```

上游 sidecar 自身带有发布路由，但 `mixsocial` 没有调用或展示这些功能；自动托管时服务只绑定 IPv4 loopback。

## 频道语义

| 频道 | 百度贴吧 | 小红书 |
| --- | --- | --- |
| 推荐 | `--tieba-forums` 中的吧；未配置且已登录时使用已关注贴吧 | sidecar 提供的首页推荐流 |
| 热榜 | 贴吧全站官方“热议话题”榜；接口失败时回退到常看 / 已关注吧的热门排序 | 对本次推荐样本按点赞、收藏、评论、分享加权排序；不是官方全站榜 |
| 关注 | 登录账号实际关注的贴吧内容，单次最多读取前 8 个吧以控制频率 | 当前 sidecar 没有关注内容流路由，频道会明确显示能力提示，不用推荐流冒充 |

小红书搜索接口支持“已关注”筛选，但它必须同时给出关键词，无法稳定组成完整关注首页，因此没有被冒充成关注流。

## 键位

| 键 | 操作 |
| --- | --- |
| `j` / `k` | 移动条目；详情页中滚动 |
| `enter` | 打开详情 |
| `/` | 搜索 |
| `1` / `2` / `3` | 推荐 / 热榜 / 关注频道 |
| `tab` / `shift+tab` | 全部、贴吧、小红书间切换 |
| `r` | 刷新 |
| `L` | 使用当前来源的官方 App 扫码登录 |
| `B` | 贴吧备用登录：遮罩导入 BDUSS |
| `l` / `f` | 点赞 / 收藏，随后需按 `y` 确认 |
| `c` | 评论，输入后需按 `y` 确认 |
| `J` / `K` | 详情页选择评论 |
| `R` | 回复选中的评论，输入后需按 `y` 确认 |
| `b` / `esc` | 从详情返回 |
| `q` | 退出 |

贴吧适配器当前是公开只读，因此其点赞、收藏、评论和回复会显示“不支持”。小红书交互需要有效登录状态。

## 配置

| 参数 / 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `--demo` | `false` | 仅运行离线演示数据 |
| `--tieba` | `true` | 启用贴吧 |
| `--xhs` | `true` | 启用小红书 |
| `--tieba-forums` / `MIXSOCIAL_TIEBA_FORUMS` | 空 | 首页常看吧，逗号分隔 |
| `--tieba-session` / `MIXSOCIAL_TIEBA_SESSION` | 用户配置目录 | 贴吧会话文件 |
| `--browser` / `MIXSOCIAL_BROWSER` | 自动查找 | 扫码登录使用的 Chromium 路径；贴吧和小红书可共用安装脚本内置版本 |
| `--xhs-endpoint` / `MIXSOCIAL_XHS_ENDPOINT` | `http://127.0.0.1:18060` | sidecar 地址 |
| `--xhs-token` / `MIXSOCIAL_XHS_TOKEN` | 空 | sidecar Bearer 令牌 |
| `--xhs-managed` | `true` | 自动启动并回收 sidecar |
| `--xhs-sidecar` / `MIXSOCIAL_XHS_SIDECAR` | 自动查找 | sidecar 可执行文件路径 |
| `--xhs-startup-timeout` | `15m` | 首次浏览器下载和启动的最长等待时间 |
| `MIXSOCIAL_XHS_SESSION` | 用户配置目录 | 小红书会话文件 |
| `MIXSOCIAL_XHS_LOG` | 用户配置目录 | sidecar 日志文件 |
| `--timeout` | `45s` | 单次请求超时 |

## 开发

```bash
go test ./...
go vet -buildvcs=false ./...
go build -buildvcs=false -o mixsocial ./cmd/mixsocial
```

适配器和 TUI 之间只通过 `internal/source.Reader`、`Interactor` 以及统一领域模型通信。sidecar 的进程生命周期由 `internal/sidecar` 管理。

接口来源与许可证记录见 [THIRD_PARTY.md](THIRD_PARTY.md)。
