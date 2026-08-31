import 'dart:convert';

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

const String xhsFeedScript = r'''(() => {
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
  const items = feeds.filter((feed) => feed && (!feed.modelType || feed.modelType === 'note')).map((feed) => {
    const card = feed.noteCard || {};
    const user = card.user || {};
    const cover = card.cover || {};
    const info = card.interactInfo || {};
    const coverUrl = first(cover.urlDefault, cover.urlPre, cover.url,
      ...(Array.isArray(cover.infoList) ? cover.infoList.map((entry) => entry && entry.url) : []));
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
      previewUrl: coverUrl,
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
        id: user.userId || '', name: user.nickname || user.nickName || '未知用户', avatar: user.avatar || '',
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
  const map = window.__INITIAL_STATE__?.note?.noteDetailMap;
  const detail = map && map[${jsonEncode(feedId)}];
  const note = detail && detail.note;
  if (!note) return '';
  const count = (value) => {
    const raw = String(value || '').replaceAll(',', '').trim();
    const unit = raw.endsWith('万') ? 10000 : 1;
    const number = Number.parseFloat(raw.replace('万', ''));
    return Number.isFinite(number) ? Math.trunc(number * unit) : 0;
  };
  const user = note.user || {};
  const info = note.interactInfo || {};
  const token = note.xsecToken || ${jsonEncode(xsecToken)};
  const first = (...values) => values.find((value) => typeof value === 'string' && value.length) || '';
  let media = Array.isArray(note.imageList) ? note.imageList.map((image) => ({
    kind: 'image',
    url: first(image.urlDefault, image.urlPre, image.url,
      ...(Array.isArray(image.infoList) ? image.infoList.map((entry) => entry && entry.url) : [])),
    previewUrl: first(image.urlPre, image.urlDefault, image.url,
      ...(Array.isArray(image.infoList) ? image.infoList.map((entry) => entry && entry.url) : [])),
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
    const commentUser = comment.userInfo || {};
    const userToken = commentUser.xsecToken || token;
    const pictureList = Array.isArray(comment.pictures) ? comment.pictures
      : Array.isArray(comment.imageList) ? comment.imageList : [];
    const replies = Array.isArray(comment.subComments)
      ? comment.subComments.map((reply) => mapComment(reply, comment.id || parentId)) : [];
    return {
      ref: {source: 'xhs', id: comment.id || '', parentId, token},
      author: {
        ref: {
          source: 'xhs', id: commentUser.userId || '', token: userToken,
          url: commentUser.userId ? 'https://www.xiaohongshu.com/user/profile/'
            + encodeURIComponent(commentUser.userId) + '?xsec_token=' + encodeURIComponent(userToken)
            + '&xsec_source=pc_note' : '',
        },
        id: commentUser.userId || '', name: commentUser.nickname || commentUser.nickName || '未知用户',
        avatar: commentUser.avatar || '',
      },
      body: comment.content || '', likes: count(comment.likeCount),
      publishedAt: comment.createTime
        ? new Date(comment.createTime > 1000000000000 ? comment.createTime : comment.createTime * 1000).toISOString()
        : null,
      replyCount: count(comment.subCommentCount), replies,
      media: pictureList.map((picture) => ({
        kind: 'image', url: picture.urlDefault || picture.urlPre || picture.url || '',
        previewUrl: picture.urlDefault || picture.urlPre || picture.url || '',
        width: picture.width || 0, height: picture.height || 0,
      })).filter((media) => media.url),
    };
  };
  const commentState = detail.comments || {};
  const comments = Array.isArray(commentState.list)
    ? commentState.list.map((comment) => mapComment(comment, note.noteId || ${jsonEncode(feedId)})) : [];
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
      id: user.userId || '', name: user.nickname || user.nickName || '未知用户', avatar: user.avatar || '',
    },
    publishedAt: note.time ? new Date(note.time > 1000000000000 ? note.time : note.time * 1000).toISOString() : null,
    stats: {
      likes: count(info.likedCount), comments: count(info.commentCount),
      favorites: count(info.collectedCount), shares: count(info.sharedCount),
    },
    media, comments, liked: info.liked === true, favorited: info.collected === true,
    nextCursor: commentState.cursor || String(comments.length),
    hasMore: commentState.hasMore === true || (!reachedEnd && comments.length > 0 && comments.length < count(info.commentCount)),
  });
})()''';

const String xhsLoadMoreCommentsScript = r'''(() => {
  const parents = [...document.querySelectorAll('.parent-comment')];
  const before = parents.length;
  const visible = (element) => {
    const rect = element.getBoundingClientRect();
    const style = getComputedStyle(element);
    return rect.width > 0 && rect.height > 0 && style.display !== 'none' && style.visibility !== 'hidden';
  };
  let clicked = 0;
  for (const button of document.querySelectorAll('.show-more')) {
    if (clicked >= 2) break;
    if (visible(button)) {
      button.click();
      clicked++;
    }
  }
  const last = parents.at(-1);
  if (last) last.scrollIntoView({block: 'end', behavior: 'auto'});
  const scroller = ['.note-scroller', '.comments-container']
    .map((selector) => document.querySelector(selector))
    .find((element) => element && element.scrollHeight > element.clientHeight);
  if (scroller) scroller.scrollBy({top: Math.max(520, scroller.clientHeight * 0.82), behavior: 'smooth'});
  else window.scrollBy({top: Math.max(520, window.innerHeight * 0.82), behavior: 'smooth'});
  return JSON.stringify({before, clicked});
})()''';

String xhsFloorRepliesScript(String feedId, String commentId) =>
    '''(() => {
  const detail = window.__INITIAL_STATE__?.note?.noteDetailMap?.[${jsonEncode(feedId)}];
  const note = detail?.note || {};
  const token = note.xsecToken || '';
  const count = (value) => {
    const raw = String(value || '').replaceAll(',', '').trim();
    const unit = raw.endsWith('万') ? 10000 : 1;
    const number = Number.parseFloat(raw.replace('万', ''));
    return Number.isFinite(number) ? Math.trunc(number * unit) : 0;
  };
  const find = (list) => {
    for (const comment of Array.isArray(list) ? list : []) {
      if (comment?.id === ${jsonEncode(commentId)}) return comment;
      const nested = find(comment?.subComments);
      if (nested) return nested;
    }
    return null;
  };
  const parent = find(detail?.comments?.list);
  if (!parent) return '';
  const mapComment = (comment) => {
    const user = comment.userInfo || {};
    const userToken = user.xsecToken || token;
    return {
      ref: {source: 'xhs', id: comment.id || '', parentId: ${jsonEncode(commentId)}, token},
      author: {
        ref: {
          source: 'xhs', id: user.userId || '', token: userToken,
          url: user.userId ? 'https://www.xiaohongshu.com/user/profile/' + encodeURIComponent(user.userId)
            + '?xsec_token=' + encodeURIComponent(userToken) + '&xsec_source=pc_note' : '',
        },
        id: user.userId || '', name: user.nickname || user.nickName || '未知用户', avatar: user.avatar || '',
      },
      body: comment.content || '', likes: count(comment.likeCount),
      publishedAt: comment.createTime
        ? new Date(comment.createTime > 1000000000000 ? comment.createTime : comment.createTime * 1000).toISOString()
        : null,
      replyCount: count(comment.subCommentCount),
    };
  };
  const comments = Array.isArray(parent.subComments) ? parent.subComments.map(mapComment) : [];
  const root = document.getElementById('comment-' + ${jsonEncode(commentId)});
  const hasButton = !!root?.querySelector('.show-more');
  return JSON.stringify({
    comments, nextCursor: String(comments.length),
    hasMore: hasButton || count(parent.subCommentCount) > comments.length,
  });
})()''';

String xhsLoadMoreFloorRepliesScript(String commentId) =>
    '''(() => {
  const root = document.getElementById('comment-' + ${jsonEncode(commentId)});
  if (!root) return false;
  root.scrollIntoView({block: 'center', behavior: 'auto'});
  const buttons = [...root.querySelectorAll('.show-more')];
  const button = buttons.find((element) => {
    const rect = element.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  });
  if (!button) return false;
  button.click();
  return true;
})()''';

String xhsProfileScript(
  String userId,
  String xsecToken, [
  String section = 'note',
]) =>
    '''(() => {
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
  const items = feeds.filter((feed) => feed && (!feed.modelType || feed.modelType === 'note')).map((feed) => {
    const card = feed.noteCard || {};
    const user = card.user || {};
    const cover = card.cover || {};
    const info = card.interactInfo || {};
    const coverUrl = first(cover.urlDefault, cover.urlPre, cover.url,
      ...(Array.isArray(cover.infoList) ? cover.infoList.map((entry) => entry && entry.url) : []));
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
        avatar: user.avatar || basic.imageb || basic.images || '',
      },
      stats: {
        likes: count(info.likedCount), comments: count(info.commentCount),
        favorites: count(info.collectedCount), shares: count(info.sharedCount),
      },
      media: coverUrl ? [{
        kind: card.type === 'video' ? 'video' : 'image',
        url: card.type === 'video' ? videoUrl : coverUrl, previewUrl: coverUrl,
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
    name: basic.nickname || '未知用户', avatar: basic.imageb || basic.images || '',
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

String xhsInteractStateScript(String feedId, String field) =>
    '''(() => {
  const note = window.__INITIAL_STATE__?.note?.noteDetailMap?.[${jsonEncode(feedId)}]?.note;
  const value = note?.interactInfo?.[${jsonEncode(field)}];
  return typeof value === 'boolean' ? String(value) : '';
})()''';

String xhsClickScript(String selector) =>
    '''(() => {
  const element = document.querySelector(${jsonEncode(selector)});
  if (!element) return false;
  element.click();
  return true;
})()''';

String xhsFollowStateScript() => r'''(() => {
  const labels = [...document.querySelectorAll('button, [role="button"]')]
    .map((node) => (node.textContent || '').replace(/\s+/g, '').trim());
  if (labels.some((text) => ['已关注', '互相关注'].includes(text))) return 'true';
  if (labels.some((text) => text === '关注')) return 'false';
  return '';
})()''';

String xhsClickFollowScript(bool value) =>
    '''(() => {
  const wanted = ${value ? "['关注']" : "['已关注', '互相关注']"};
  const candidates = [...document.querySelectorAll('button, [role="button"]')];
  const element = candidates.find((node) => wanted.includes((node.textContent || '').replace(/\\s+/g, '').trim()));
  if (!element) return false;
  element.click();
  return true;
})()''';

const String xhsConfirmUnfollowScript = r'''(() => {
  const candidates = [...document.querySelectorAll('button, [role="button"]')];
  const element = candidates.find((node) => ['确认取消', '取消关注', '确定']
    .includes((node.textContent || '').replace(/\s+/g, '').trim()));
  if (!element) return false;
  element.click();
  return true;
})()''';

String xhsCommentScript(String body) =>
    '''(() => {
  const placeholder = document.querySelector('div.input-box div.content-edit span');
  if (placeholder) placeholder.click();
  const input = document.querySelector('div.input-box div.content-edit p.content-input');
  if (!input) return false;
  input.focus();
  input.textContent = ${jsonEncode(body)};
  input.dispatchEvent(new InputEvent('input', {bubbles: true, inputType: 'insertText', data: ${jsonEncode(body)}}));
  return true;
})()''';

const String xhsSubmitCommentScript = r'''(() => {
  const button = document.querySelector('div.bottom button.submit');
  if (!button || button.disabled) return false;
  button.click();
  return true;
})()''';

String xhsCommentVisibleScript(String body) =>
    '''(() => {
  const container = document.querySelector('.comments-container');
  return container ? container.innerText.includes(${jsonEncode(body)}) : false;
})()''';

String xhsReplyTargetScript(String commentId) =>
    '''(() => {
  const comment = document.querySelector(${jsonEncode('#comment-$commentId')});
  const button = comment && comment.querySelector('.right .interactions .reply');
  if (!button) return false;
  button.scrollIntoView({block: 'center'});
  button.click();
  return true;
})()''';
