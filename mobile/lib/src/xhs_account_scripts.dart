import 'xhs_comment_scripts.dart';

// Read the signed-in account, never userPageData (the profile being viewed).
// No cookies, signatures or account identifiers are sent outside the WebView.
const xhsCurrentProfileScript =
    '(() => {$xhsAvatarHelpers'
    r'''
  const unwrap = (value) => {
    for (let depth = 0; depth < 6 && value && typeof value === 'object'; depth++) {
      if (value.__v_isRef === true || 'value' in value || '_value' in value || '_rawValue' in value) {
        value = value.value ?? value._value ?? value._rawValue;
      } else break;
    }
    return value;
  };
  const text = (value) => typeof unwrap(value) === 'string' ? unwrap(value).trim() : '';
  const validId = (value) => /^[a-zA-Z0-9_-]{1,128}$/.test(value);
  const state = unwrap(window.__INITIAL_STATE__);
  const user = unwrap(unwrap(state?.user)?.userInfo);
  const guest = unwrap(user?.guest);
  if (guest === true || guest === 'true' || guest === 1) return '';
  const stateId = text(user?.userId ?? user?.user_id);
  if (stateId && !validId(stateId)) return '';

  // Only the sidebar's explicit "me" link can serve as the fallback identity.
  // Note-author links and the address bar belong to other users and are ignored.
  let ownLink = null;
  for (const node of document.querySelectorAll('.main-container .user .link-wrapper')) {
    const label = (node.textContent || '').replace(/\s+/g, '');
    if (!['我', '我的', '我的主页'].includes(label)) continue;
    const href = node.getAttribute('href') || node.closest('a[href]')?.getAttribute('href');
    if (!href) continue;
    try {
      const url = new URL(href, location.href);
      if (url.protocol !== 'https:' || url.hostname !== 'www.xiaohongshu.com' || url.username || url.password) continue;
      const match = /^\/user\/profile\/([a-zA-Z0-9_-]{1,128})\/?$/.exec(url.pathname);
      if (!match) continue;
      if (ownLink && ownLink.id !== match[1]) return '';
      ownLink = {id: match[1], token: url.searchParams.get('xsec_token') || ''};
    } catch (_) {}
  }
  if (stateId && ownLink && stateId !== ownLink.id) return '';
  const id = stateId || ownLink?.id || '';
  if (!validId(id)) return '';
  const token = ownLink?.token || '';
  const url = new URL('https://www.xiaohongshu.com/user/profile/' + encodeURIComponent(id));
  if (token) url.searchParams.set('xsec_token', token);
  url.searchParams.set('xsec_source', 'pc_note');
  return JSON.stringify({
    ref: {source: 'xhs', id, token, url: url.href}, id,
    name: text(user?.nickname ?? user?.nickName) || '我',
    ...avatarFields(user),
  });
})()''';
