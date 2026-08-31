import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'app_controller.dart';
import 'design_system.dart';
import 'forum_screen.dart';
import 'reader_tools_screen.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, required this.controller});

  final MixsocialController controller;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  bool _checking = true;
  bool _xhsLoggedIn = false;
  bool _tiebaCredentialSaved = false;
  Object? _xhsStatusError;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshStatus());
  }

  Future<void> _refreshStatus() async {
    if (mounted) setState(() => _checking = true);
    final tiebaSaved = await widget.controller.tieba.hasCredential();
    var xhsLoggedIn = false;
    Object? xhsError;
    try {
      xhsLoggedIn = await widget.controller.xhs.isLoggedIn();
    } catch (error) {
      xhsError = error;
    }
    if (!mounted) return;
    setState(() {
      _checking = false;
      _tiebaCredentialSaved = tiebaSaved;
      _xhsLoggedIn = xhsLoggedIn;
      _xhsStatusError = xhsError;
    });
  }

  Future<void> _openXhsLogin() async {
    final loggedIn = await Navigator.push<bool>(
      context,
      MaterialPageRoute<bool>(
        builder: (_) => XhsLoginScreen(controller: widget.controller),
      ),
    );
    if (!mounted) return;
    if (loggedIn == true) {
      setState(() {
        _xhsLoggedIn = true;
        _xhsStatusError = null;
      });
      await _refreshFeed();
    }
  }

  Future<void> _openTiebaLogin() async {
    final loggedIn = await Navigator.push<bool>(
      context,
      MaterialPageRoute<bool>(
        builder: (_) => TiebaLoginScreen(controller: widget.controller),
      ),
    );
    if (!mounted || loggedIn != true) return;
    setState(() => _tiebaCredentialSaved = true);
    await _refreshFeed();
  }

  Future<void> _importBduss() async {
    final textController = TextEditingController();
    var hidden = true;
    final credential = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setDialogState) =>
            AlertDialog(
              title: const Text('安全导入贴吧 BDUSS'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    '可粘贴 BDUSS 原值，或 BDUSS=…; STOKEN=… 形式的 Cookie。导入前会由贴吧接口校验。',
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    key: const Key('tieba-bduss-input'),
                    controller: textController,
                    autofocus: true,
                    obscureText: hidden,
                    enableSuggestions: false,
                    autocorrect: false,
                    keyboardType: TextInputType.visiblePassword,
                    decoration: InputDecoration(
                      labelText: 'BDUSS',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        tooltip: hidden ? '显示' : '隐藏',
                        onPressed: () => setDialogState(() => hidden = !hidden),
                        icon: Icon(
                          hidden
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '凭据仅进入系统安全存储，不写入普通数据库。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    final value = textController.text.trim();
                    if (value.isNotEmpty) Navigator.pop(context, value);
                  },
                  child: const Text('校验并保存'),
                ),
              ],
            ),
      ),
    );
    textController.dispose();
    if (credential == null || !mounted) return;
    await _withProgress(() async {
      await widget.controller.tieba.loginWithCredential(credential);
      if (mounted) setState(() => _tiebaCredentialSaved = true);
      await _refreshFeed();
      if (mounted) _showMessage('贴吧登录成功，BDUSS 已保存到系统安全存储');
    });
  }

  Future<void> _logoutTieba() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('退出贴吧登录？'),
        content: const Text('这会从本机安全存储中删除 BDUSS。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('退出登录'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _withProgress(() async {
      await widget.controller.tieba.logout();
      if (mounted) setState(() => _tiebaCredentialSaved = false);
      await _refreshFeed();
    });
  }

  Future<void> _refreshFeed() async {
    try {
      await widget.controller.refresh();
    } catch (_) {
      // The account action already succeeded. Feed errors are rendered on the
      // home screen and must not be confused with login failures.
    }
  }

  Future<void> _withProgress(Future<void> Function() action) async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      await action();
    } catch (error) {
      if (mounted) _showMessage(error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  void _showMessage(String message, {bool error = false}) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final xhsCard = _AccountCard(
      color: const Color(0xffe9274f),
      icon: Icons.auto_awesome,
      title: '小红书',
      connected: _xhsLoggedIn,
      status: _xhsLoggedIn
          ? '已登录，Cookie 由系统 WebView 持久化'
          : _xhsStatusError == null
          ? '未检测到登录状态'
          : '暂时无法检查登录状态',
      detail: _xhsStatusError?.toString(),
      action: FilledButton.icon(
        onPressed: _checking ? null : _openXhsLogin,
        icon: const Icon(Icons.language),
        label: Text(_xhsLoggedIn ? '打开登录页' : '使用 WebView 登录'),
      ),
    );
    final tiebaCard = _AccountCard(
      color: const Color(0xff3478f6),
      icon: Icons.forum_outlined,
      title: '百度贴吧',
      connected: _tiebaCredentialSaved,
      status: _tiebaCredentialSaved ? '已登录并保存 BDUSS' : '尚未登录',
      detail: _tiebaCredentialSaved
          ? '凭据将在应用启动时从 Android Keystore 恢复。'
          : '推荐在百度官方网页中完成登录；也可以安全导入已有 BDUSS。',
      action: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FilledButton.icon(
            onPressed: _checking ? null : _openTiebaLogin,
            icon: const Icon(Icons.language),
            label: Text(_tiebaCredentialSaved ? '重新网页登录' : '使用 WebView 登录'),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _checking ? null : _importBduss,
                  icon: const Icon(Icons.key_outlined),
                  label: Text(_tiebaCredentialSaved ? '更换 BDUSS' : '导入 BDUSS'),
                ),
              ),
              if (_tiebaCredentialSaved) ...<Widget>[
                const SizedBox(width: AppSpacing.sm),
                IconButton.filledTonal(
                  tooltip: '退出登录',
                  onPressed: _checking ? null : _logoutTieba,
                  icon: const Icon(Icons.logout),
                ),
              ],
            ],
          ),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的'),
        actions: <Widget>[
          IconButton(
            tooltip: '重新检查',
            onPressed: _checking ? null : _refreshStatus,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshStatus,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final wide = constraints.maxWidth >= 760;
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: <Widget>[
                Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1040),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        if (_checking)
                          const LinearProgressIndicator(minHeight: 2),
                        const SizedBox(height: AppSpacing.md),
                        if (wide)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Expanded(child: xhsCard),
                              const SizedBox(width: AppSpacing.lg),
                              Expanded(child: tiebaCard),
                            ],
                          )
                        else ...<Widget>[
                          xhsCard,
                          const SizedBox(height: AppSpacing.md),
                          tiebaCard,
                        ],
                        const SizedBox(height: AppSpacing.xl),
                        Text(
                          '阅读工具',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Card(
                          child: Column(
                            children: <Widget>[
                              ListTile(
                                leading: const Icon(Icons.forum_outlined),
                                title: const Text('贴吧目录'),
                                subtitle: const Text('已关注贴吧、最近访问和按吧浏览'),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => Navigator.push<void>(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) => ForumHubScreen(
                                      controller: widget.controller,
                                    ),
                                  ),
                                ),
                              ),
                              const Divider(),
                              ListTile(
                                leading: const Icon(Icons.history),
                                title: const Text('浏览历史'),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => Navigator.push<void>(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) => LocalLibraryScreen(
                                      controller: widget.controller,
                                      kind: LocalLibraryKind.history,
                                    ),
                                  ),
                                ),
                              ),
                              const Divider(),
                              ListTile(
                                leading: const Icon(Icons.bookmarks_outlined),
                                title: const Text('本地收藏'),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => Navigator.push<void>(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) => LocalLibraryScreen(
                                      controller: widget.controller,
                                      kind: LocalLibraryKind.saved,
                                    ),
                                  ),
                                ),
                              ),
                              const Divider(),
                              ListTile(
                                leading: const Icon(Icons.filter_alt_outlined),
                                title: const Text('内容与阅读设置'),
                                subtitle: const Text('按吧/关键词过滤、隐藏视频、阅读密度'),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => Navigator.push<void>(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) => ContentSettingsScreen(
                                      controller: widget.controller,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(AppSpacing.lg),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                const Icon(Icons.security_outlined),
                                const SizedBox(width: AppSpacing.md),
                                Expanded(
                                  child: Text(
                                    'Cookie 和 BDUSS 不进入信息流、详情或普通缓存数据库。请勿把 BDUSS 发给他人。',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodyMedium,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xl),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class TiebaLoginScreen extends StatefulWidget {
  const TiebaLoginScreen({super.key, required this.controller});

  final MixsocialController controller;

  @override
  State<TiebaLoginScreen> createState() => _TiebaLoginScreenState();
}

class _TiebaLoginScreenState extends State<TiebaLoginScreen> {
  static final _loginUri = Uri.parse(
    'https://passport.baidu.com/v2/?login&tpl=tb&u='
    'https%3A%2F%2Ftieba.baidu.com%2Findex.html',
  );

  WebViewController? _webViewController;
  bool _loading = true;
  bool _checking = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      final controller = WebViewController();
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) {
            final uri = Uri.tryParse(request.url);
            return uri != null && _isAllowedBaiduPage(uri)
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (_) {
            if (mounted) {
              setState(() {
                _loading = false;
                _error = null;
              });
            }
          },
          onWebResourceError: (WebResourceError error) {
            if (error.isForMainFrame != true || !mounted) return;
            setState(() {
              _loading = false;
              _error = StateError('百度登录页加载失败：${error.description}');
            });
          },
        ),
      );
      if (!mounted) return;
      setState(() => _webViewController = controller);
      await controller.loadRequest(_loginUri);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  Future<void> _reload() async {
    final controller = _webViewController;
    if (controller == null || _checking) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    await controller.loadRequest(_loginUri);
  }

  Future<void> _finish() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final loggedIn = await widget.controller.tieba.loginFromWebViewCookies();
      if (!mounted) return;
      if (loggedIn) {
        Navigator.pop(context, true);
      } else {
        _showMessage('尚未检测到 BDUSS，请在网页内完成登录后重试');
      }
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  void _showMessage(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final webViewController = _webViewController;
    return Scaffold(
      appBar: AppBar(
        title: const Text('贴吧登录'),
        actions: <Widget>[
          IconButton(
            tooltip: '重新加载',
            onPressed: _loading || _checking ? null : _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: Stack(
              children: <Widget>[
                if (webViewController != null)
                  Positioned.fill(
                    child: WebViewWidget(
                      key: const Key('tieba-login-webview'),
                      controller: webViewController,
                    ),
                  ),
                if (_loading || webViewController == null)
                  Positioned.fill(
                    child: ColoredBox(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      child: const AppLoadingView(
                        title: '正在打开百度登录',
                        message: '登录凭据只会保存在系统安全存储',
                      ),
                    ),
                  ),
                if (_error != null)
                  Positioned.fill(
                    child: ColoredBox(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      child: AppStateView(
                        icon: Icons.cloud_off_outlined,
                        iconColor: Theme.of(context).colorScheme.error,
                        title: '百度登录页加载失败',
                        message: _error.toString(),
                        actionLabel: '重新加载',
                        onAction: _reload,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Row(
                children: <Widget>[
                  const Expanded(
                    child: Text('请在百度官方页面完成登录。检测到的 BDUSS 经贴吧接口校验后才会写入系统安全存储。'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: _loading || _checking ? null : _finish,
                    child: _checking
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('我已完成'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

bool _isAllowedBaiduPage(Uri uri) =>
    uri.scheme == 'https' &&
    (uri.host == 'baidu.com' || uri.host.endsWith('.baidu.com'));

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.color,
    required this.icon,
    required this.title,
    required this.connected,
    required this.status,
    required this.action,
    this.detail,
  });

  final Color color;
  final IconData icon;
  final String title;
  final bool connected;
  final String status;
  final String? detail;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                CircleAvatar(
                  backgroundColor: color,
                  foregroundColor: Colors.white,
                  child: Icon(icon),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Semantics(
                  label: connected ? '已连接' : '未连接',
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: connected
                          ? colors.primaryContainer
                          : colors.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(AppRadii.sm),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: AppSpacing.xs,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            connected
                                ? Icons.check_circle_outline
                                : Icons.circle_outlined,
                            size: 15,
                          ),
                          const SizedBox(width: AppSpacing.xs),
                          Text(
                            connected ? '已连接' : '未连接',
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(status, style: Theme.of(context).textTheme.titleSmall),
            if (detail != null) ...<Widget>[
              const SizedBox(height: 5),
              Text(detail!, style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: action),
          ],
        ),
      ),
    );
  }
}

class XhsLoginScreen extends StatefulWidget {
  const XhsLoginScreen({super.key, required this.controller});

  final MixsocialController controller;

  @override
  State<XhsLoginScreen> createState() => _XhsLoginScreenState();
}

class _XhsLoginScreenState extends State<XhsLoginScreen> {
  bool _loading = true;
  bool _checking = false;
  bool _polling = false;
  Object? _error;
  Timer? _loginPoll;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    _loginPoll?.cancel();
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      await widget.controller.xhs.openLogin();
      _loginPoll = Timer.periodic(
        const Duration(milliseconds: 1200),
        (_) => unawaited(_pollLogin()),
      );
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pollLogin() async {
    if (_polling || _checking || !mounted) return;
    _polling = true;
    try {
      if (await widget.controller.xhs.isLoggedIn() && mounted) {
        _loginPoll?.cancel();
        Navigator.pop(context, true);
      }
    } catch (_) {
      // The page can briefly transition after QR confirmation. The next poll
      // will check the hydrated desktop page again.
    } finally {
      _polling = false;
    }
  }

  @override
  void dispose() {
    _loginPoll?.cancel();
    super.dispose();
  }

  Future<void> _finish() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final loggedIn = await widget.controller.xhs.isLoggedIn();
      if (!mounted) return;
      if (loggedIn) {
        _loginPoll?.cancel();
        Navigator.pop(context, true);
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('尚未检测到登录状态，请在网页内完成登录后重试')));
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('小红书登录'),
        actions: <Widget>[
          IconButton(
            tooltip: '重新加载',
            onPressed: _loading || _checking ? null : _open,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: widget.controller.xhs.webView(
                    key: const Key('xhs-login-webview'),
                  ),
                ),
                if (_loading)
                  Positioned.fill(
                    child: ColoredBox(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      child: const AppLoadingView(
                        title: '正在打开小红书登录',
                        message: '登录状态将由系统 WebView 安全保存',
                      ),
                    ),
                  ),
                if (_error != null)
                  Positioned.fill(
                    child: ColoredBox(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      child: AppStateView(
                        icon: Icons.cloud_off_outlined,
                        iconColor: Theme.of(context).colorScheme.error,
                        title: '小红书登录页加载失败',
                        message: _error.toString(),
                        actionLabel: '重新加载',
                        onAction: _open,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Row(
                children: <Widget>[
                  const Expanded(
                    child: Text(
                      '上方是 PC 网页端，可扫码或验证码登录。'
                      '登录成功后会自动返回，Cookie 仅保存在系统 WebView。',
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: _loading || _checking ? null : _finish,
                    child: _checking
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('我已完成'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
