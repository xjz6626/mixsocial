import 'dart:convert';

const String xhsFeedScript = r'''(() => {
  const unwrap = (value) => value && value.value !== undefined
      ? value.value
      : value && value._value !== undefined ? value._value : value;
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
    const profileUrl = user.userId
      ? `https://www.xiaohongshu.com/user/profile/${encodeURIComponent(user.userId)}?xsec_token=${encodeURIComponent(feed.xsecToken || '')}&xsec_source=pc_note`
      : '';
    const media = coverUrl ? [{
      kind: card.type === 'video' ? 'video' : 'image',
      url: card.type === 'video' ? '' : coverUrl,
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
  const images = Array.isArray(note.imageList) ? note.imageList.map((image) => ({
    kind: 'image', url: image.urlDefault || image.urlPre || '',
    previewUrl: image.urlDefault || image.urlPre || '', width: image.width || 0, height: image.height || 0,
  })).filter((media) => media.url) : [];
  const streamGroups = note.video?.media?.stream || {};
  const streams = Object.values(streamGroups).flatMap((value) => Array.isArray(value) ? value : []);
  const stream = streams.find((value) => value && value.defaultStream && value.masterUrl)
      || streams.find((value) => value && value.masterUrl);
  if (stream) images.push({
    kind: 'video', url: stream.masterUrl, previewUrl: '', format: stream.streamDesc || stream.format || '',
    width: stream.width || 0, height: stream.height || 0,
    durationMilliseconds: stream.duration || (note.video?.capa?.duration || 0) * 1000,
  });
  const comments = Array.isArray(detail.comments?.list) ? detail.comments.list.map((comment) => ({
    ref: {source: 'xhs', id: comment.id || '', parentId: note.noteId || ${jsonEncode(feedId)}, token},
    author: {
      ref: {source: 'xhs', id: comment.userInfo?.userId || ''},
      id: comment.userInfo?.userId || '', name: comment.userInfo?.nickname || comment.userInfo?.nickName || '未知用户',
      avatar: comment.userInfo?.avatar || '',
    },
    body: comment.content || '', likes: count(comment.likeCount),
  })) : [];
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
    media: images, comments, liked: info.liked === true, favorited: info.collected === true,
  });
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

const String xhsOpenProfileMenuScript = r'''(() => {
  const selectors = ['button[aria-label*="更多"]', '[class*="more"]', '[class*="More"]', '.reds-icon.more'];
  for (const selector of selectors) {
    const candidates = [...document.querySelectorAll(selector)].filter((node) => {
      const rect = node.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    });
    if (candidates.length) {
      candidates[candidates.length - 1].click();
      return true;
    }
  }
  return false;
})()''';

String xhsClickBlockScript(bool value) =>
    '''(() => {
  const labels = ${value ? "['拉黑', '屏蔽该用户', '屏蔽用户']" : "['解除拉黑', '取消屏蔽']"};
  const candidates = [...document.querySelectorAll('button, [role="button"], li, .menu-item')];
  const element = candidates.find((node) => labels.includes((node.textContent || '').replace(/\\s+/g, '').trim()));
  if (!element) return false;
  element.click();
  return true;
})()''';

const String xhsConfirmDangerousActionScript = r'''(() => {
  const candidates = [...document.querySelectorAll('button, [role="button"]')];
  const element = candidates.find((node) => ['确认', '确定', '拉黑', '解除']
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
