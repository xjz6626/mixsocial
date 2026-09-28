import 'dart:convert';

import 'xhs_comment_scripts.dart';

// Unlike commentRoot (which finds the expansion container), this must never
// broaden a reply target to its parent: doing so could like the wrong comment.
const _commentInteractionHelpers = r'''
  const explicitCommentId = (element) => element?.dataset?.commentId
    || (element?.id || '').replace(/^comment-/, '');
  const ownCommentId = (element) => {
    const component = element?.__vueParentComponent;
    for (const state of [component?.props, component?.setupState]) {
      for (const key of ['comment', 'commentInfo', 'commentData', 'item']) {
        const id = commentId(unwrap(state?.[key]));
        if (id) return id;
      }
    }
    return '';
  };
  const exactCommentElement = (id) => {
    const exact = document.getElementById('comment-' + id) || document.getElementById(id);
    if (exact) return exact;
    return [...document.querySelectorAll('.comment-item, [data-comment-id]')]
      .find((node) => explicitCommentId(node)
        ? explicitCommentId(node) === id : ownCommentId(node) === id) || null;
  };
  const belongsToComment = (element, root, id) => {
    const owner = element.closest?.('.comment-item, [data-comment-id]');
    if (!owner || owner === root) return true;
    return explicitCommentId(owner) ? explicitCommentId(owner) === id
      : ownCommentId(owner) === id;
  };
  const commentLikeButton = (root, id) => root
    ? [...root.querySelectorAll('.like-wrapper, .like-container, .like-button, [data-action="like"], [aria-label="点赞"], [aria-label="取消点赞"]')]
      .find((element) => visible(element) && belongsToComment(element, root, id)) || null
    : null;
''';

String xhsCommentLikeStateScript(String noteId, String targetId) =>
    '''(() => {
  $xhsCommentStateHelpers
  $_commentInteractionHelpers
  const id = ${jsonEncode(targetId)};
  const element = exactCommentElement(id);
  if (!element || !commentLikeButton(element, id)) return '';
  const comment = liveComment(element, id)
    || findComment(rootComments(noteDetail(${jsonEncode(noteId)})), id);
  const liked = field(comment, 'liked', 'isLiked', 'is_liked');
  if (typeof liked === 'boolean') return String(liked);
  const pressed = commentLikeButton(element, id)?.getAttribute?.('aria-pressed');
  return pressed === 'true' || pressed === 'false' ? pressed : '';
})()''';

String xhsClickCommentLikeScript(String targetId) =>
    '''(() => {
  $xhsCommentStateHelpers
  $_commentInteractionHelpers
  const id = ${jsonEncode(targetId)};
  const button = commentLikeButton(exactCommentElement(id), id);
  if (!button) return false;
  button.click();
  return true;
})()''';
