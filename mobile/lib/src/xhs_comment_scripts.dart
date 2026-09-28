// Shared by the detail reader and the controls that expand its comments.
// SSR snapshots, Vue refs and live component props all occur on the web page.
const String xhsCommentStateHelpers = r'''
  const unwrap = (value) => {
    for (let depth = 0; value && typeof value === 'object' && depth < 8; depth++) {
      const key = ['value', '_value', '_rawValue'].find((key) => value[key] !== undefined);
      if (!key) break;
      const next = value[key];
      if (next === value) break;
      value = next;
    }
    return value;
  };
  const field = (object, ...keys) => {
    object = unwrap(object);
    for (const key of keys) {
      const value = unwrap(object?.[key]);
      if (value !== undefined && value !== null) return value;
    }
    return undefined;
  };
  const list = (value) => {
    value = unwrap(value);
    if (Array.isArray(value)) return value.map(unwrap).filter(Boolean);
    const entries = field(value, 'list', 'comments');
    return Array.isArray(entries) ? entries.map(unwrap).filter(Boolean) : [];
  };
  const commentId = (comment) => String(field(comment, 'id', 'commentId', 'comment_id') || '');
  const subComments = (comment) => list(field(comment, 'subComments', 'sub_comments', 'replies'));
  const liveComment = (element, targetId = '') => {
    let component = element?.__vueParentComponent;
    for (let depth = 0; component && depth < 6; depth++, component = component.parent) {
      for (const state of [component.props, component.setupState]) {
        for (const key of ['comment', 'commentInfo', 'commentData', 'item']) {
          const value = unwrap(state?.[key]);
          if (commentId(value) && (!targetId || commentId(value) === targetId)) return value;
        }
      }
    }
    return null;
  };
  const commentRoot = (targetId) => {
    let element = document.getElementById('comment-' + targetId)
      || document.getElementById(targetId);
    if (!element) element = [...document.querySelectorAll('.parent-comment, .comment-item, [data-comment-id]')]
      .find((node) => node.dataset?.commentId === targetId
        || node.id === 'comment-' + targetId || node.id === targetId
        || !!liveComment(node, targetId));
    // The id belongs to the comment item; the expand control is its sibling.
    return element?.closest('.parent-comment') || element || null;
  };
  const visible = (element) => {
    // Flutter also reads this page while its WebView is offscreen. A zero
    // layout rect does not mean that the page's control is hidden or disabled.
    if (element.disabled || element.getAttribute?.('aria-disabled') === 'true') return false;
    for (let node = element; node; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (node.hidden || style.display === 'none' || style.visibility === 'hidden') return false;
    }
    return true;
  };
  const moreButton = (root) => {
    if (!root) return null;
    const moreText = /(展开|查看|更多|继续).*(回复|评论)|(回复|评论).*(展开|查看|更多|继续)/;
    return [...root.querySelectorAll('.show-more, .show-more-container, .more-replies, button, [role="button"], a')]
      .find((element) => {
        const text = (element.textContent || '').replace(/\s+/g, '');
        return visible(element) && !/(收起|加载中)/.test(text)
          && (element.matches('.show-more, .show-more-container, .more-replies') || moreText.test(text));
      }) || null;
  };
  const noteDetail = (id) => field(field(field(window.__INITIAL_STATE__, 'note'), 'noteDetailMap'), id);
  const commentState = (detail) => field(detail, 'comments') || {};
  const rootComments = (detail) => {
    const result = list(commentState(detail));
    for (const element of document.querySelectorAll('.parent-comment')) {
      const comment = liveComment(element) || liveComment(element.querySelector('.comment-item'));
      if (!comment) continue;
      const index = result.findIndex((entry) => commentId(entry) === commentId(comment));
      if (index < 0) result.push(comment);
      else result[index] = comment;
    }
    return result;
  };
  const findComment = (comments, targetId) => {
    for (const comment of comments) {
      if (commentId(comment) === targetId) return comment;
      const nested = findComment(subComments(comment), targetId);
      if (nested) return nested;
    }
    return null;
  };
''';

const String xhsAvatarHelpers = r'''
  const avatarUrls = (...users) => {
    const result = [];
    const add = (value, depth = 0) => {
      if (!value || depth > 4) return;
      if (typeof value === 'string') {
        const url = value.trim();
        if (url && !result.includes(url)) result.push(url);
      } else if (Array.isArray(value)) {
        value.forEach((entry) => add(entry, depth + 1));
      } else if (typeof value === 'object') {
        for (const key of ['url', 'urlDefault', 'urlPre', 'image', 'infoList']) add(value[key], depth + 1);
      }
    };
    for (const user of users) {
      for (const key of ['avatar', 'image', 'image_url', 'avatarUrl', 'avatar_url', 'imageb', 'images']) add(user?.[key]);
    }
    return result;
  };
  const avatarFields = (...users) => {
    const urls = avatarUrls(...users);
    return {avatar: urls[0] || '', avatar_urls: urls};
  };
''';
