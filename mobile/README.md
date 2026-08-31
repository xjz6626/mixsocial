# Mixsocial Android 客户端

当前移动端以 Android 为优先，Flutter 负责界面与系统 WebView，贴吧能力通过本地
`gomobile` AAR 调用 Go 核心。凭据只进入系统安全存储，不写入普通数据库。

主界面采用“首页 / 搜索 / 我的”导航：手机使用底部导航，平板和宽屏自动切换侧边栏，
并保留各标签页状态。首页保留平台和推荐/热榜/关注筛选，搜索页同时支持贴吧全站主题与
小红书公开笔记；列表接近底部时自动读取下一页并去重，宽屏瀑布流会扩展到三至四列。
主题可跟随系统或固定为浅色/深色；加载、空结果和错误恢复使用统一状态组件并提供读屏
语义。贴吧纯文字主题使用紧凑文字卡片，不显示无意义的空图片占位。

贴吧阅读链路还包括：输入吧名直达、完整关注吧目录、最近访问、吧内搜索、按回复/发帖
时间排序、主题和楼中楼分页、倒序、只看楼主、楼层/楼主标记。本地阅读工具提供历史、
跨来源收藏、断网信息流回退、紧凑/标准/舒适密度、图片手势缩放，以及按吧、关键词、
视频和全部媒体过滤。按作者屏蔽已明确移除；完整取舍见
[TiebaLite 功能对照](../TIEBALITE_PARITY.md)。

小红书使用真实的 Windows Chrome 桌面 UA 和 PC 宽视口，登录页支持扫码或验证码，
并拦截唤起 App 的非 HTTP 跳转。搜索支持 PC 端五组筛选；详情页支持评论与楼中楼连续加载；
点击作者可浏览主页简介和笔记/收藏/点赞分类。完整范围见
[小红书移动端功能对照](../XHS_PARITY.md)。

## 环境

- Flutter 3.47 或更高版本（Dart 3.12+）
- Go 1.24.2 或更高版本
- JDK 17
- Android SDK Platform 37、Build Tools 36 和 NDK r28c
- `gomobile` 与 `gobind` 使用 `go.mod` 中固定的 `golang.org/x/mobile` 版本

首次准备 Go 移动工具：

```bash
go install golang.org/x/mobile/cmd/gomobile@v0.0.0-20250911085028-6912353760cf
go install golang.org/x/mobile/cmd/gobind@v0.0.0-20250911085028-6912353760cf
```

不要额外执行 `gomobile init`；当前版本会尝试拉取不受 `go.mod` 固定的
`gobind@latest`，可能引入更高的 Go 版本要求。

## 构建与检查

先设置 `ANDROID_HOME`（或 `ANDROID_SDK_ROOT`）、`ANDROID_NDK_HOME` 与 Java 17，
然后在仓库根目录执行：

```bash
make mobile-aar
make mobile-check
cd mobile
flutter build apk --debug
flutter build apk --release
cd ..
make mobile-apk-check
```

AAR 输出到
`mobile/packages/mixsocial_core/android/libs/mobilecore.aar`，包含 Android ARM64 与
x86_64，生成物不提交到 Git。APK 输出到 `mobile/build/app/outputs/flutter-apk/`。
未提供 `ANDROID_KEYSTORE_*` 环境变量时，release 构建会使用调试证书，只能作为本机
安装预览；正式发布仍必须使用下述 CI Secrets。品牌图标主图与生成说明保存在
[`assets/branding/`](assets/branding/)，Android 密度资源由主图生成。
`mobile-apk-check` 会复核 APK 签名、包名、版本信息，并确认 ARM64 与 x86_64 的 Go
运行库均已打包。

## GitHub Actions 发布

`.github/workflows/android-release.yml` 在推送 `v*` 标签时构建并发布 Android APK，
也可以从 Actions 页面手动选择已有标签，或更新 `.github/release-request.json` 后通过
标准 Git 推送启动已有标签。工作流会校验标签与 `pubspec.yaml` 版本、运行 Go/Flutter
检查、生成 AAR、验证 APK 签名，并同时上传 SHA-256 文件。

正式标签自动发布前，需要在仓库 Actions Secrets 中配置以下四项，凭据不会进入
源码、普通数据库或构建日志：

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

`v0.2.0` 可通过发布请求或手动运行工作流并允许调试签名来发布预览版。未配置上述
Secrets 时，后续由标签自动触发的构建会停止发布，避免不同的临时调试证书导致 APK
无法覆盖升级。

## 真机验证闸门

在继续 SQLite/媒体缓存和 iOS 适配前，至少完成以下 Android 真机验证：

1. 小红书 PC WebView 扫码/验证码登录不唤起 App，与贴吧登录后均杀进程并重启，确认登录状态仍有效。
2. 验证推荐、全站搜索、小红书搜索筛选和作者主页，以及关注吧目录、单吧列表/搜索/排序。
3. 验证倒序、只看楼主、本地收藏/历史/离线回退，以及按吧、关键词和视频过滤。
4. 验证小红书评论/楼中楼连续加载，以及点赞、收藏、关注、评论和回复；贴吧仍保持公开只读。
5. 验证全部/小红书/贴吧切换后的布局选择与滚动位置恢复。
6. 观察数千关注吧目录和长列表滚动、前后台切换、WebView 销毁后的内存表现。

贴吧支持百度官方页面的可见 WebView 登录及安全导入 BDUSS。WebView 登录成功后，
应用读取百度域的 BDUSS/STOKEN，交给 Go 核心校验，并将有效凭据保存到系统安全存储。
