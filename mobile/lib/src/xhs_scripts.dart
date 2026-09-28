import 'dart:convert';

import 'xhs_comment_scripts.dart';

const String xhsDesktopPageScript = r'''(() => {
  let viewport = document.querySelector('meta[name="viewport"]');
  if (!viewport) {
    viewport = document.createElement('meta');
    viewport.name = 'viewport';
    document.head.appendChild(viewport);
  }
  viewport.content = 'width=1280, initial-scale=0.3, minimum-scale=0.1, maximum-scale=5, user-scalable=yes';
  document.documentElement.style.minWidth = '1180px';
  if (document.body) document.body.style.minWidth = '1180px';
  return true;
})()''';

const String xhsOpenLoginScript = r'''(() => {
  if (document.querySelector('.main-container .user .link-wrapper .channel')) return 'loggedIn';
  if (document.querySelector('.login-container .qrcode-img')) return 'ready';
  const candidates = [...document.querySelectorAll('button, [role="button"], a')];
  const login = candidates.find((node) => (node.textContent || '').replace(/\s+/g, '') === '登录');
  if (!login) return 'waiting';
  login.click();
  return 'opened';
})()''';

const String xhsLoginStatusScript = r'''(() => {
  const unwrap = (value) => value && value.value !== undefined
      ? value.value
      : value && value._value !== undefined ? value._value
      : value && value._rawValue !== undefined ? value._rawValue : value;
  const user = unwrap(window.__INITIAL_STATE__?.user?.userInfo);
  if (user && user.guest !== true && (user.userId || user.user_id || user.nickname)) return true;
  return !!document.querySelector('.main-container .user .link-wrapper .channel');
})()''';

const String xhsFeedScript =
    '(() => {$xhsAvatarHelpers'
    r'''
  const unwrap = (value) => value && value.value !== undefined
      ? value.value
      : value && value._value !== undefined ? value._value
      : value && value._rawValue !== undefined ? value._rawValue : value;
  const state = window.__INITIAL_STATE__;
  const feeds = unwrap(state && state.feed && state.feed.feeds);
  if (!Array.isArray(feeds)) return '';
  const count = (value) => {
    if (typeof value === 'number') return Math.trunc(value);
    const raw = String(value || '').replaceAll(',', '').trim();
    const unit = raw.endsWith('万') ? 10000 : 1;
    const number = Number.parseFloat(raw.replace('万', ''));
    return Number.isFinite(number) ? Math.trunc(number * unit) : 0;
  };
  const first = (...values) => values.find((value) => typeof value === 'string' && value.length) || '';
  const imageEntries = (image) => Array.isArray(image?.infoList) ? image.infoList.filter(Boolean) : [];
  const sceneImage = (image, pattern) => imageEntries(image)
    .find((entry) => pattern.test(String(entry.imageScene || entry.image_scene || entry.scene || '')))?.url || '';
  const highImage = (image) => first(sceneImage(image, /ori|origin/i), image?.urlDefault,
    sceneImage(image, /dft|default/i), image?.url,
    ...imageEntries(image).map((entry) => entry.url), image?.urlPre);
  const previewImage = (image) => first(image?.urlPre, sceneImage(image, /prv|preview/i),
    image?.urlDefault, image?.url, ...imageEntries(image).map((entry) => entry.url));
  const items = feeds.filter((feed) => feed && (!feed.modelType || feed.modelType === 'note')).map((feed) => {
    const card = feed.noteCard || {};
    const user = card.user || {};
    const cover = card.cover || {};
    const info = card.interactInfo || {};
    const coverUrl = highImage(cover);
    const coverPreviewUrl = previewImage(cover);
    const streamGroups = card.video?.media?.stream || {};
    const streams = Object.values(streamGroups).flatMap((value) =>
      Array.isArray(value) ? value : value && typeof value === 'object' ? [value] : []);
    const stream = streams.find((value) => value && value.defaultStream)
      || streams.find((value) => value);
    const videoUrl = stream ? first(stream.masterUrl, stream.url,
      ...(Array.isArray(stream.backupUrls) ? stream.backupUrls : [])) : '';
    const profileUrl = user.userId
      ? `https://www.xiaohongshu.com/user/profile/${encodeURIComponent(user.userId)}?xsec_token=${encodeURIComponent(feed.xsecToken || '')}&xsec_source=pc_note`
      : '';
    const media = coverUrl ? [{
      kind: card.type === 'video' ? 'video' : 'image',
      url: card.type === 'video' ? videoUrl : coverUrl,
      previewUrl: coverPreviewUrl || coverUrl,
      width: cover.width || 0,
      height: cover.height || 0,
      durationMilliseconds: card.video && card.video.capa ? (card.video.capa.duration || 0) * 1000 : 0,
    }] : [];
    return {
      ref: {
        source: 'xhs', id: feed.id || '', token: feed.xsecToken || '',
        url: feed.id ? `https://www.xiaohongshu.com/explore/${encodeURIComponent(feed.id)}?xsec_token=${encodeURIComponent(feed.xsecToken || '')}&xsec_source=pc_feed` : '',
      },
      title: card.displayTitle || '', summary: card.desc || '',
      author: {
        ref: {source: 'xhs', id: user.userId || '', token: feed.xsecToken || '', url: profileUrl},
        id: user.userId || '', name: user.nickname || user.nickName || '未知用户', ...avatarFields(user),
      },
      stats: {
        likes: count(info.likedCount), comments: count(info.commentCount),
        favorites: count(info.collectedCount), shares: count(info.sharedCount),
      },
      media, liked: info.liked === true, favorited: info.collected === true,
    };
  }).filter((item) => item.ref.id);
  return JSON.stringify({items});
})()''';

String xhsDetailScript(String feedId, String xsecToken) =>
    '''(() => {
  $xhsCommentStateHelpers
  $xhsAvatarHelpers
  const detail = noteDetail(${jsonEncode(feedId)});
  const note = field(detail, 'note');
  if (!note) return '';
  const count = (value) => {
    const raw = String(value || '').replaceAll(',', '').trim();
    const unit = raw.endsWith('万') ? 10000 : 1;
    const number = Number.parseFloat(raw.replace('万', ''));
    return Number.isFinite(number) ? Math.trunc(number * unit) : 0;
  };
  const user = field(note, 'user') || {};
  const info = field(note, 'interactInfo', 'interact_info') || {};
  const token = field(note, 'xsecToken', 'xsec_token') || ${jsonEncode(xsecToken)};
  const first = (...values) => values.find((value) => typeof value === 'string' && value.length) || '';
  const imageEntries = (image) => Array.isArray(image?.infoList) ? image.infoList.filter(Boolean) : [];
  const sceneImage = (image, pattern) => imageEntries(image)
    .find((entry) => pattern.test(String(entry.imageScene || entry.image_scene || entry.scene || '')))?.url || '';
  const highImage = (image) => first(sceneImage(image, /ori|origin/i), image?.urlDefault,
    sceneImage(image, /dft|default/i), image?.url,
    ...imageEntries(image).map((entry) => entry.url), image?.urlPre);
  const previewImage = (image) => first(image?.urlPre, sceneImage(image, /prv|preview/i),
    image?.urlDefault, image?.url, ...imageEntries(image).map((entry) => entry.url));
  let media = Array.isArray(note.imageList) ? note.imageList.map((image) => ({
    kind: 'image',
    url: highImage(image),
    previewUrl: previewImage(image),
    width: image.width || 0, height: image.height || 0,
  })).filter((media) => media.url) : [];
  const streamGroups = note.video?.media?.stream || {};
  const streams = Object.values(streamGroups).flatMap((value) =>
    Array.isArray(value) ? value : value && typeof value === 'object' ? [value] : []);
  const stream = streams.find((value) => value && value.defaultStream)
      || streams.find((value) => value);
  const videoUrl = stream ? first(stream.masterUrl, stream.url,
    ...(Array.isArray(stream.backupUrls) ? stream.backupUrls : [])) : '';
  if (videoUrl) media = [{
    kind: 'video', url: videoUrl, previewUrl: media[0]?.previewUrl || '', format: stream.streamDesc || stream.format || '',
    width: stream.width || 0, height: stream.height || 0,
    durationMilliseconds: stream.duration || (note.video?.capa?.duration || 0) * 1000,
  }];
  const mapComment = (comment, parentId) => {
    const root = commentRoot(commentId(comment));
    comment = liveComment(root, commentId(comment))
      || liveComment(root?.querySelector('.comment-item'), commentId(comment)) || comment;
    const commentUser = field(comment, 'userInfo', 'user_info', 'user') || {};
    const userId = field(commentUser, 'userId', 'user_id') || '';
    const userToken = field(commentUser, 'xsecToken', 'xsec_token') || token;
    const pictureList = Array.isArray(comment.pictures) ? comment.pictures
      : list(field(comment, 'imageList', 'image_list'));
    const replies = subComments(comment).map((reply) => mapComment(reply, commentId(comment) || parentId));
    const created = field(comment, 'createTime', 'create_time');
    return {
      ref: {source: 'xhs', id: commentId(comment), parentId, token},
      author: {
        ref: {
          source: 'xhs', id: userId, token: userToken,
          url: userId ? 'https://www.xiaohongshu.com/user/profile/'
            + encodeURIComponent(userId) + '?xsec_token=' + encodeURIComponent(userToken)
            + '&xsec_source=pc_note' : '',
        },
        id: userId, name: commentUser.nickname || commentUser.nickName || '未知用户',
        ...avatarFields(commentUser),
      },
      body: field(comment, 'content') || '', likes: count(field(comment, 'likeCount', 'like_count')),
      liked: typeof field(comment, 'liked', 'isLiked', 'is_liked') === 'boolean'
        ? field(comment, 'liked', 'isLiked', 'is_liked') : null,
      publishedAt: created
        ? new Date(created > 1000000000000 ? created : created * 1000).toISOString()
        : null,
      replyCount: Math.max(count(field(comment, 'subCommentCount', 'sub_comment_count')), replies.length), replies,
      media: pictureList.map((picture) => ({
        kind: 'image', url: highImage(picture),
        previewUrl: previewImage(picture),
        width: picture.width || 0, height: picture.height || 0,
      })).filter((media) => media.url),
    };
  };
  const state = commentState(detail);
  const comments = rootComments(detail).map((comment) => mapComment(comment, note.noteId || ${jsonEncode(feedId)}));
  const reachedEnd = !!document.querySelector('.comments-container .end-container, .note-scroller .end-container');
  return JSON.stringify({
    ref: {
      source: 'xhs', id: note.noteId || ${jsonEncode(feedId)}, token,
      url: 'https://www.xiaohongshu.com/explore/' + encodeURIComponent(note.noteId || ${jsonEncode(feedId)})
        + '?xsec_token=' + encodeURIComponent(token) + '&xsec_source=pc_feed',
    },
    title: note.title || '', summary: note.desc || '', body: note.desc || '',
    author: {
      ref: {
        source: 'xhs', id: user.userId || '', token,
        url: user.userId ? 'https://www.xiaohongshu.com/user/profile/' + encodeURIComponent(user.userId)
          + '?xsec_token=' + encodeURIComponent(token) + '&xsec_source=pc_note' : '',
      },
      id: user.userId || '', name: user.nickname || user.nickName || '未知用户', ...avatarFields(user),
    },
    publishedAt: note.time ? new Date(note.time > 1000000000000 ? note.time : note.time * 1000).toISOString() : null,
    stats: {
      likes: count(info.likedCount), comments: count(info.commentCount),
      favorites: count(info.collectedCount), shares: count(info.sharedCount),
    },
    media, comments, liked: info.liked === true, favorited: info.collected === true,
    nextCursor: field(state, 'cursor') || String(comments.length),
    hasMore: reachedEnd ? false : field(state, 'hasMore', 'has_more') !== undefined
      ? !!field(state, 'hasMore', 'has_more')
      : !reachedEnd && count(info.commentCount) > comments.length,
  });
})()''';

const String xhsLoadMoreCommentsScript = r'''(() => {
  const parents = [...document.querySelectorAll('.parent-comment')];
  const before = parents.length;
  const last = parents.at(-1);
  if (last) last.scrollIntoView({block: 'end', behavior: 'auto'});
  const scroller = ['.note-scroller', '.comments-container']
    .map((selector) => document.querySelector(selector))
    .find((element) => element && element.scrollHeight > element.clientHeight);
  if (scroller) scroller.scrollBy({top: Math.max(520, scroller.clientHeight * 0.82), behavior: 'auto'});
  else window.scrollBy({top: Math.max(520, window.innerHeight * 0.82), behavior: 'auto'});
  return JSON.stringify({before});
})()''';

String xhsFloorRepliesScript(String feedId, String commentId) =>
    '''(() => {
  $xhsCommentStateHelpers
  $xhsAvatarHelpers
  const detail = noteDetail(${jsonEncode(feedId)});
  const note = field(detail, 'note') || {};
  const token = field(note, 'xsecToken', 'xsec_token') || '';
  const count = (value) => {
    const raw = String(value || '').replaceAll(',', '').trim();
    const unit = raw.endsWith('万') ? 10000 : 1;
    const number = Number.parseFloat(raw.replace('万', ''));
    return Number.isFinite(number) ? Math.trunc(number * unit) : 0;
  };
  const first = (...values) => values.find((value) => typeof value === 'string' && value.length) || '';
  const imageEntries = (image) => Array.isArray(image?.infoList) ? image.infoList.filter(Boolean) : [];
  const sceneImage = (image, pattern) => imageEntries(image)
    .find((entry) => pattern.test(String(entry.imageScene || entry.image_scene || entry.scene || '')))?.url || '';
  const highImage = (image) => first(sceneImage(image, /ori|origin/i), image?.urlDefault,
    sceneImage(image, /dft|default/i), image?.url,
    ...imageEntries(image).map((entry) => entry.url), image?.urlPre);
  const previewImage = (image) => first(image?.urlPre, sceneImage(image, /prv|preview/i),
    image?.urlDefault, image?.url, ...imageEntries(image).map((entry) => entry.url));
  const targetId = ${jsonEncode(commentId)};
  const root = commentRoot(targetId);
  const parent = liveComment(root, targetId)
    || liveComment(root?.querySelector('.comment-item'), targetId)
    || findComment(rootComments(detail), targetId);
  if (!parent) return '';
  const mapComment = (comment) => {
    const user = field(comment, 'userInfo', 'user_info', 'user') || {};
    const userId = field(user, 'userId', 'user_id') || '';
    const userToken = field(user, 'xsecToken', 'xsec_token') || token;
    const pictureList = Array.isArray(comment.pictures) ? comment.pictures
      : list(field(comment, 'imageList', 'image_list'));
    const created = field(comment, 'createTime', 'create_time');
    return {
      ref: {source: 'xhs', id: commentId(comment), parentId: targetId, token},
      author: {
        ref: {
          source: 'xhs', id: userId, token: userToken,
          url: userId ? 'https://www.xiaohongshu.com/user/profile/' + encodeURIComponent(userId)
            + '?xsec_token=' + encodeURIComponent(userToken) + '&xsec_source=pc_note' : '',
        },
        id: userId, name: user.nickname || user.nickName || '未知用户', ...avatarFields(user),
      },
      body: field(comment, 'content') || '', likes: count(field(comment, 'likeCount', 'like_count')),
      liked: typeof field(comment, 'liked', 'isLiked', 'is_liked') === 'boolean'
        ? field(comment, 'liked', 'isLiked', 'is_liked') : null,
      publishedAt: created
        ? new Date(created > 1000000000000 ? created : created * 1000).toISOString()
        : null,
      replyCount: count(field(comment, 'subCommentCount', 'sub_comment_count')),
      media: pictureList.map((picture) => ({
        kind: 'image', url: highImage(picture),
        previewUrl: previewImage(picture),
        width: picture.width || 0, height: picture.height || 0,
      })).filter((media) => media.url),
    };
  };
  const comments = subComments(parent).map(mapComment);
  const more = field(parent, 'subCommentHasMore', 'sub_comment_has_more', 'hasMore', 'has_more');
  return JSON.stringify({
    comments, nextCursor: JSON.stringify({count: comments.length,
      cursor: field(parent, 'subCommentCursor', 'sub_comment_cursor') || ''}),
    hasMore: more !== undefined ? !!more
      : !!moreButton(root) || count(field(parent, 'subCommentCount', 'sub_comment_count')) > comments.length,
  });
})()''';

String xhsLoadMoreFloorRepliesScript(String commentId) =>
    '''(() => {
  $xhsCommentStateHelpers
  const targetId = ${jsonEncode(commentId)};
  const root = commentRoot(targetId);
  if (!root) return false;
  root.scrollIntoView({block: 'center', behavior: 'auto'});
  const button = moreButton(root);
  if (!button) return false;
  for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup']) {
    button.dispatchEvent(new MouseEvent(type, {bubbles: true, view: window}));
  }
  button.click();
  return true;
})()''';

String xhsProfileScript(
  String userId,
  String xsecToken, [
  String section = 'note',
]) =>
    '''(() => {
  $xhsAvatarHelpers
  const unwrap = (value) => value && value.value !== undefined
      ? value.value
      : value && value._value !== undefined ? value._value
      : value && value._rawValue !== undefined ? value._rawValue : value;
  const state = window.__INITIAL_STATE__?.user;
  const pageData = unwrap(state?.userPageData);
  const notes = unwrap(state?.notes);
  if (!pageData || !Array.isArray(notes)) return '';
  const active = unwrap(state?.activeTab) || {};
  const requestedSection = ${jsonEncode(section)};
  if (active.query && active.query !== requestedSection) return '';
  const feeds = Array.isArray(notes[active.index || 0]) ? notes[active.index || 0] : [];
  const basic = pageData.basicInfo || {};
  const interactions = Array.isArray(pageData.interactions) ? pageData.interactions : [];
  const count = (value) => {
    const raw = String(value || '').replaceAll(',', '').trim();
    const unit = raw.endsWith('万') ? 10000 : 1;
    const number = Number.parseFloat(raw.replace('万', ''));
    return Number.isFinite(number) ? Math.trunc(number * unit) : 0;
  };
  const first = (...values) => values.find((value) => typeof value === 'string' && value.length) || '';
  const imageEntries = (image) => Array.isArray(image?.infoList) ? image.infoList.filter(Boolean) : [];
  const sceneImage = (image, pattern) => imageEntries(image)
    .find((entry) => pattern.test(String(entry.imageScene || entry.image_scene || entry.scene || '')))?.url || '';
  const highImage = (image) => first(sceneImage(image, /ori|origin/i), image?.urlDefault,
    sceneImage(image, /dft|default/i), image?.url,
    ...imageEntries(image).map((entry) => entry.url), image?.urlPre);
  const previewImage = (image) => first(image?.urlPre, sceneImage(image, /prv|preview/i),
    image?.urlDefault, image?.url, ...imageEntries(image).map((entry) => entry.url));
  const items = feeds.filter((feed) => feed && (!feed.modelType || feed.modelType === 'note')).map((feed) => {
    const card = feed.noteCard || {};
    const user = card.user || {};
    const cover = card.cover || {};
    const info = card.interactInfo || {};
    const coverUrl = highImage(cover);
    const coverPreviewUrl = previewImage(cover);
    const streamGroups = card.video?.media?.stream || {};
    const streams = Object.values(streamGroups).flatMap((value) =>
      Array.isArray(value) ? value : value && typeof value === 'object' ? [value] : []);
    const stream = streams.find((value) => value && value.defaultStream)
      || streams.find((value) => value);
    const videoUrl = stream ? first(stream.masterUrl, stream.url,
      ...(Array.isArray(stream.backupUrls) ? stream.backupUrls : [])) : '';
    const token = feed.xsecToken || ${jsonEncode(xsecToken)};
    const profileUrl = user.userId
      ? 'https://www.xiaohongshu.com/user/profile/' + encodeURIComponent(user.userId)
        + '?xsec_token=' + encodeURIComponent(token) + '&xsec_source=pc_note' : '';
    return {
      ref: {
        source: 'xhs', id: feed.id || '', token,
        url: feed.id ? 'https://www.xiaohongshu.com/explore/' + encodeURIComponent(feed.id)
          + '?xsec_token=' + encodeURIComponent(token) + '&xsec_source=pc_feed' : '',
      },
      title: card.displayTitle || '', summary: card.desc || '',
      author: {
        ref: {source: 'xhs', id: user.userId || ${jsonEncode(userId)}, token, url: profileUrl},
        id: user.userId || ${jsonEncode(userId)}, name: user.nickname || user.nickName || basic.nickname || '未知用户',
        ...avatarFields(user, basic),
      },
      stats: {
        likes: count(info.likedCount), comments: count(info.commentCount),
        favorites: count(info.collectedCount), shares: count(info.sharedCount),
      },
      media: coverUrl ? [{
        kind: card.type === 'video' ? 'video' : 'image',
        url: card.type === 'video' ? videoUrl : coverUrl, previewUrl: coverPreviewUrl || coverUrl,
        width: cover.width || 0, height: cover.height || 0,
        durationMilliseconds: card.video?.capa ? (card.video.capa.duration || 0) * 1000 : 0,
      }] : [],
      liked: info.liked === true, favorited: info.collected === true,
    };
  }).filter((item) => item.ref.id);
  const end = !!document.querySelector('.end-container');
  return JSON.stringify({
    ref: {
      source: 'xhs', id: ${jsonEncode(userId)}, token: ${jsonEncode(xsecToken)},
      url: 'https://www.xiaohongshu.com/user/profile/' + encodeURIComponent(${jsonEncode(userId)})
        + '?xsec_token=' + encodeURIComponent(${jsonEncode(xsecToken)}) + '&xsec_source=pc_note',
    },
    name: basic.nickname || '未知用户', ...avatarFields(basic),
    description: basic.desc || '', redId: basic.redId || '', location: basic.ipLocation || '',
    stats: interactions.map((entry) => ({name: entry.name || entry.type || '', count: String(entry.count || '0')})),
    items, nextCursor: items.length ? 'more' : '', hasMore: items.length > 0 && !end,
  });
})()''';

const String xhsOpenSearchFiltersScript = r'''(() => {
  const button = document.querySelector('div.filter');
  if (!button) return false;
  for (const type of ['pointerenter', 'mouseenter', 'mouseover']) {
    button.dispatchEvent(new MouseEvent(type, {bubbles: true, view: window}));
  }
  button.click();
  return true;
})()''';

String xhsSelectSearchFilterScript(String group, String option) =>
    '''(() => {
  const groups = [...document.querySelectorAll('div.filter-panel div.filters')];
  const target = groups.find((element) => {
    const label = element.querySelector(':scope > span');
    return (label?.textContent || '').trim() === ${jsonEncode(group)};
  });
  if (!target) return false;
  const choice = [...target.querySelectorAll('div.tags')]
    .find((element) => (element.textContent || '').trim() === ${jsonEncode(option)});
  if (!choice) return false;
  choice.click();
  return true;
})()''';

String xhsActivateChannelScript(String label) =>
    '''(() => {
  const label = ${jsonEncode(label)};
  const candidates = [...document.querySelectorAll('a, button, [role="tab"], .channel')];
  const element = candidates.find((node) => (node.textContent || '').trim() === label);
  if (!element) return false;
  element.click();
  return true;
})()''';

// A profile page can contain follow controls for recommended accounts too.
// Only inspect its own header, and reject ambiguous or mismatched pages.
const _xhsProfileFollowHelpers = r'''
  const label = (node) => (node.textContent || '').replace(/\s+/g, '').trim();
  const available = (node) => !node.disabled
    && node.getAttribute('aria-disabled') !== 'true'
    && !node.closest('[hidden], [aria-hidden="true"]');
  const followButtons = () => {
    let pageId;
    try {
      const path = new URL(location.href).pathname;
      const match = path.match(/^\/user\/profile\/([^/]+)\/?$/);
      pageId = match ? decodeURIComponent(match[1]) : '';
    } catch (_) { return []; }
    if (!pageId || (expectedProfileId && pageId !== expectedProfileId)) return [];
    const roots = [...document.querySelectorAll('.user-page .user, '
      + '.user-profile .user-info, .user-info, .user-header, .profile-header')];
    const candidates = [...new Set(roots.flatMap((root) =>
      [...root.querySelectorAll('button, [role="button"], .follow-btn')]))];
    return candidates.filter((node) => available(node)
      && !node.closest('.note-item, .comment-item, .recommend-user, .user-list-item')
      && ['关注', '已关注', '互相关注'].includes(label(node)));
  };
''';

String xhsFollowStateScript([String profileId = '']) =>
    '''(() => {
  const expectedProfileId = ${jsonEncode(profileId)};
  $_xhsProfileFollowHelpers
  const buttons = followButtons();
  if (buttons.length !== 1) return '';
  return label(buttons[0]) === '关注' ? 'false' : 'true';
})()''';

String xhsClickFollowScript(bool value, [String profileId = '']) =>
    '''(() => {
  const expectedProfileId = ${jsonEncode(profileId)};
  $_xhsProfileFollowHelpers
  const wanted = ${value ? "['关注']" : "['已关注', '互相关注']"};
  const buttons = followButtons();
  if (buttons.length !== 1 || !wanted.includes(label(buttons[0]))) return false;
  buttons[0].click();
  return true;
})()''';

const String xhsConfirmUnfollowScript = r'''(() => {
  const operation = window.__mixsocialXhsInteraction?.pending;
  if (!operation || operation.action !== 'follow' || operation.value
      || operation.status !== 'pending' || operation.sent) return false;
  const dialogs = [...document.querySelectorAll('[role="dialog"], .reds-modal, '
    + '.reds-dialog, .modal-container, .dialog-container, .confirm-container')]
    .filter((dialog) => /取消关注|不再关注/.test(dialog.textContent || ''));
  const candidates = [...new Set(dialogs.flatMap((dialog) =>
    [...dialog.querySelectorAll('button, [role="button"], .confirm-btn')]))]
    .filter((node) => !node.disabled && node.getAttribute('aria-disabled') !== 'true'
      && !node.closest('[hidden], [aria-hidden="true"]')
      && ['确认取消', '取消关注', '确定']
        .includes((node.textContent || '').replace(/\s+/g, '').trim()));
  if (candidates.length !== 1) return false;
  candidates[0].click();
  return true;
})()''';
