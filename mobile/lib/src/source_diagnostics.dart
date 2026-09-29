import 'package:flutter/foundation.dart';
import 'models.dart';

enum SourceFailureKind {
  login,
  verification,
  rateLimit,
  timeout,
  network,
  unavailable,
}

class SourceFailure {
  const SourceFailure(this.kind, this.message);
  final SourceFailureKind kind;
  final String message;

  factory SourceFailure.from(Object error) {
    // Inspect, but never retain, raw error strings: upstream errors may contain
    // URLs, request bodies or credentials. UI/copy uses these fixed messages.
    final raw = error.toString().toLowerCase();
    if (RegExp(
      r'验证码|验证后|风控|captcha|verify|verification|\b461\b|\b471\b',
    ).hasMatch(raw)) {
      return const SourceFailure(
        SourceFailureKind.verification,
        '平台要求验证，请打开官方网页完成验证后重试',
      );
    }
    if (RegExp(r'频繁|限流|rate.?limit|\b429\b').hasMatch(raw)) {
      return const SourceFailure(SourceFailureKind.rateLimit, '操作频繁，请稍后再试');
    }
    if (RegExp(r'超时|timeout|timed out|deadline').hasMatch(raw)) {
      return const SourceFailure(
        SourceFailureKind.timeout,
        '请求超时；若是发言等写操作，请先刷新核对结果，不要立即重发',
      );
    }
    if (RegExp(
      r'网络|socket|network|连接|connection|resolve host|offline',
    ).hasMatch(raw)) {
      return const SourceFailure(
        SourceFailureKind.network,
        '网络暂时不可用；已保存的登录凭据不会因此被删除',
      );
    }
    if (RegExp(r'登录|凭据|bduss.*失效|unauth|login|\b401\b').hasMatch(raw)) {
      return const SourceFailure(
        SourceFailureKind.login,
        '登录状态无法确认，请重新验证登录或打开官方登录页',
      );
    }
    return const SourceFailure(
      SourceFailureKind.unavailable,
      '平台数据暂时不可用，可重试或打开官方网页查看',
    );
  }
}

/// A fixed user-facing message; raw platform errors stay out of the UI.
String safeSourceMessage(Object error) => SourceFailure.from(error).message;

String safeLocalMessage(Object error) =>
    error is FormatException ? error.message : '本地数据操作失败，请重试';

class DiagnosticEvent {
  const DiagnosticEvent({
    required this.source,
    required this.operation,
    required this.failure,
    required this.at,
  });
  final SourceId source;
  final String operation;
  final SourceFailure failure;
  final DateTime at;
  String get safeText =>
      '${at.toIso8601String()} ${source.label} $operation ${failure.kind.name}: ${failure.message}';
}

class SourceDiagnostics extends ChangeNotifier {
  final List<DiagnosticEvent> _events = <DiagnosticEvent>[];
  List<DiagnosticEvent> get events => List.unmodifiable(_events.reversed);

  void record(SourceId source, String operation, Object error) {
    const allowed = <String>{'登录验证', '作者主页', '读取内容', '官方网页', '接口探测'};
    _events.add(
      DiagnosticEvent(
        source: source,
        operation: allowed.contains(operation) ? operation : '读取内容',
        failure: SourceFailure.from(error),
        at: DateTime.now(),
      ),
    );
    if (_events.length > 50) _events.removeAt(0);
    notifyListeners();
  }

  String exportText() => events.map((event) => event.safeText).join('\n');
  void clear() {
    _events.clear();
    notifyListeners();
  }
}

final sourceDiagnostics = SourceDiagnostics();

enum TiebaSessionState {
  signedOut,
  saved,
  verified,
  expired,
  verificationRequired,
  unavailable,
}

class TiebaSessionStatus {
  const TiebaSessionStatus(
    this.state, {
    this.userId = '',
    this.username = '',
    this.checkedAt,
    this.message = '',
  });
  final TiebaSessionState state;
  final String userId;
  final String username;
  final DateTime? checkedAt;
  final String message;
  bool get verified => state == TiebaSessionState.verified;
  String get label => switch (state) {
    TiebaSessionState.signedOut => '尚未保存登录凭据',
    TiebaSessionState.saved => '已保存凭据，登录状态待验证',
    TiebaSessionState.verified => '登录已验证',
    TiebaSessionState.expired => '登录失效，请重新登录',
    TiebaSessionState.verificationRequired => '需要在官方网页完成验证',
    TiebaSessionState.unavailable => '暂时无法验证，凭据仍保留',
  };

  factory TiebaSessionStatus.fromResponse(Map<String, Object?> data) {
    final loggedIn = data['LoggedIn'] ?? data['loggedIn'];
    final id = (data['UserID'] ?? data['userId'] ?? '').toString();
    return TiebaSessionStatus(
      loggedIn == true && id.isNotEmpty
          ? TiebaSessionState.verified
          : TiebaSessionState.expired,
      userId: id,
      username: (data['Username'] ?? data['username'] ?? '').toString(),
      checkedAt: DateTime.now(),
    );
  }

  factory TiebaSessionStatus.fromFailure(Object error) {
    final failure = SourceFailure.from(error);
    final raw = error.toString().toLowerCase();
    return TiebaSessionStatus(
      failure.kind == SourceFailureKind.verification
          ? TiebaSessionState.verificationRequired
          : RegExp(
              r'bduss.*失效|cookie.*(?:失效|无效|缺少)|z_c0|凭据.*失效|未登录|not.?logged|invalid.?credential|\b401\b',
            ).hasMatch(raw)
          ? TiebaSessionState.expired
          : TiebaSessionState.unavailable,
      message: failure.message,
      checkedAt: DateTime.now(),
    );
  }
}
