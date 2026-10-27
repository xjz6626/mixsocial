import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'models.dart';
import 'official_page_screen.dart';
import 'source_diagnostics.dart';

bool hasAuthorIdentity(Author author) => author.ref.isIdentifiable;

/// Native actions wait for confirmation; the official page is an explicit fallback.
Future<void> showAuthorActions(
  BuildContext context,
  MixsocialController controller,
  Author author,
) async {
  if (!hasAuthorIdentity(author)) return;
  final direct = controller.supports(
    author.ref.source,
    SourceCapability.follow,
  );
  final blocked = controller.isAuthorBlocked(author.ref);
  final state = direct
      ? controller.readFollowing(author.ref, fallback: author.following)
      : Future<bool>.value(false);
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(author.name),
            subtitle: Text(author.ref.source.label),
          ),
          if (direct)
            FutureBuilder<bool>(
              future: state,
              builder: (context, snapshot) {
                final waiting =
                    snapshot.connectionState != ConnectionState.done;
                final following = snapshot.data ?? false;
                return ListTile(
                  leading: Icon(
                    following
                        ? Icons.person_remove_outlined
                        : Icons.person_add_alt,
                  ),
                  title: Text(
                    waiting
                        ? '读取关注状态…'
                        : snapshot.hasError
                        ? '重试读取关注状态'
                        : following
                        ? '取消关注作者'
                        : '关注作者',
                  ),
                  subtitle: Text(
                    snapshot.hasError
                        ? safeSourceMessage(snapshot.error!)
                        : '同步到${author.ref.source.label}账号',
                  ),
                  onTap: waiting
                      ? null
                      : () => Navigator.pop(
                          context,
                          snapshot.hasError
                              ? 'retry'
                              : following
                              ? 'unfollow'
                              : 'follow',
                        ),
                );
              },
            ),
          if (author.ref.source != SourceId.xhs)
            ListTile(
              leading: const Icon(Icons.open_in_browser),
              title: const Text('打开官方作者主页'),
              onTap: () => Navigator.pop(context, 'official'),
            ),
          ListTile(
            leading: const Icon(Icons.person_off_outlined),
            title: Text(blocked ? '解除屏蔽作者' : '屏蔽作者'),
            subtitle: const Text('仅在本机隐藏内容'),
            onTap: () => Navigator.pop(context, 'block'),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted) return;
  if (action == 'block') {
    await toggleAuthorBlock(context, controller, author);
  } else if (action == 'official') {
    await openOfficialAuthorFollow(context, controller, author.ref);
  } else if (action == 'retry') {
    await showAuthorActions(context, controller, author);
  } else if (action == 'follow' || action == 'unfollow') {
    final value = action == 'follow';
    try {
      final warning = await controller.follow(author.ref, value);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(warning ?? (value ? '已关注' : '已取消关注'))),
        );
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(safeSourceMessage(error))));
      }
    }
  }
}

Future<bool> toggleAuthorBlock(
  BuildContext context,
  MixsocialController controller,
  Author author,
) async {
  if (!hasAuthorIdentity(author)) return false;
  final blocked = controller.isAuthorBlocked(author.ref);
  if (!blocked) {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('屏蔽 ${author.name}？'),
        content: Text(
          '在本机隐藏这位${author.ref.source.label}作者的帖子、评论和楼中楼。可在“内容与阅读设置”中解除屏蔽；原站关注关系不变。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('屏蔽'),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;
  }
  try {
    await controller.setAuthorBlocked(author, !blocked);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            blocked ? '已解除屏蔽 ${author.name}' : '已屏蔽 ${author.name}',
          ),
        ),
      );
    }
    return true;
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('更新屏蔽失败：${safeLocalMessage(error)}')),
      );
    }
    return false;
  }
}

Future<void> openOfficialAuthorFollow(
  BuildContext context,
  MixsocialController controller,
  ProfileRef profile,
) async {
  await Navigator.push<void>(
    context,
    MaterialPageRoute<void>(
      builder: (_) => OfficialPageScreen(
        source: profile.source,
        title: '${profile.source.label}作者关注管理',
        load: () async {
          if (profile.source == SourceId.tieba) {
            // Resolve the canonical username from the numeric user ID first.
            final page = await controller.profile(profile);
            return controller.tieba.authorInteractionController(page.ref);
          }
          if (profile.source == SourceId.zhihu) {
            return controller.zhihu.authorInteractionController(profile);
          }
          throw ArgumentError('该来源没有官方关注页面');
        },
      ),
    ),
  );
}
