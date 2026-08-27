# Mixsocial Android 客户端

当前移动端以 Android 为优先，Flutter 负责界面与系统 WebView，贴吧能力通过本地
`gomobile` AAR 调用 Go 核心。凭据只进入系统安全存储，不写入普通数据库。

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
gomobile init
```

## 构建与检查

先设置 `ANDROID_HOME`（或 `ANDROID_SDK_ROOT`）、`ANDROID_NDK_HOME` 与 Java 17，
然后在仓库根目录执行：

```bash
make mobile-aar
make mobile-check
cd mobile && flutter build apk --debug
```

AAR 输出到
`mobile/packages/mixsocial_core/android/libs/mobilecore.aar`，包含 Android ARM64 与
x86_64，生成物不提交到 Git。APK 输出到 `mobile/build/app/outputs/flutter-apk/`。

## 真机验证闸门

在继续 SQLite/媒体缓存和 iOS 适配前，至少完成以下 Android 真机验证：

1. 小红书和贴吧 WebView 登录后杀进程并重启，确认登录状态仍有效。
2. 验证推荐、搜索、关注、详情解析以及图片/视频入口。
3. 验证点赞、收藏、关注、屏蔽、评论和回复；平台屏蔽失败时确认本地屏蔽仍生效。
4. 验证全部/小红书/贴吧切换后的布局选择与滚动位置恢复。
5. 观察长列表滚动、前后台切换和 WebView 销毁后的内存表现。

贴吧支持百度官方页面的可见 WebView 登录及安全导入 BDUSS。WebView 登录成功后，
应用读取百度域的 BDUSS/STOKEN，交给 Go 核心校验，并将有效凭据保存到系统安全存储。
