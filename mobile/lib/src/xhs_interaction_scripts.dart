import 'dart:convert';

// The website owns request construction, signatures and cookies. Observe its
// response instead of trusting optimistic Vue state or matching old comment text.
// Request field names were checked against ReaJason/xhs, xhs/core.py:
// https://github.com/ReaJason/xhs/blob/master/xhs/core.py
const xhsInstallInteractionObserverScript = r'''(() => {
  if (window.__mixsocialXhsInteraction) return true;
  const bridge = {pending: null};
  const finish = (operation, status, message, extra = {}) => {
    if (bridge.pending !== operation || operation.status !== 'pending') return;
    Object.assign(operation, {status, message}, extra);
  };
  const bodyObject = (body) => {
    if (typeof body === 'string') {
      try { return JSON.parse(body); } catch (_) {
        try { return Object.fromEntries(new URLSearchParams(body)); } catch (_) {}
      }
    }
    if (typeof FormData !== 'undefined' && body instanceof FormData) {
      return Object.fromEntries(body.entries());
    }
    if (body instanceof URLSearchParams) return Object.fromEntries(body.entries());
    return body && typeof body === 'object' ? body : {};
  };
  const observe = (method, url, body, unreadableBody = false) => {
    const operation = bridge.pending;
    if (!operation) return null;
    let uri;
    try { uri = new URL(url, location.href); } catch (_) { return null; }
    if (uri.protocol !== 'https:' ||
        !(uri.hostname === 'xiaohongshu.com' || uri.hostname.endsWith('.xiaohongshu.com')) ||
        String(method).toUpperCase() !== 'POST') return null;
    const suffix = operation.action === 'comment' ? 'comment/post'
      : operation.action === 'like' ? 'note/' + (operation.value ? 'like' : 'dislike')
      : operation.action === 'favorite' ? 'note/' + (operation.value ? 'collect' : 'uncollect')
      : operation.action === 'follow' ? 'user/' + (operation.value ? 'follow' : 'unfollow')
      : operation.action === 'commentLike' ? 'comment/' + (operation.value ? 'like' : 'dislike')
      : null;
    if (!suffix) return null;
    const family = operation.action === 'comment' ? 'comment/post'
      : operation.action === 'like' ? 'note/(?:like|dislike)'
      : operation.action === 'favorite' ? 'note/(?:collect|uncollect)'
      : operation.action === 'follow' ? 'user/(?:follow|unfollow)'
      : 'comment/(?:like|dislike)';
    if (!new RegExp('^/api/sns/web/v\\d+/' + family + '/?$').test(uri.pathname)) return null;
    const data = bodyObject(body) || {};
    const mismatch = (message) => {
      finish(operation, 'error', message + '，已阻止发送');
      throw new Error('Interaction request did not match the selected target');
    };
    if (unreadableBody) return mismatch('无法读取网页请求内容，无法确认互动目标');
    if (operation.action === 'follow') {
      const profile = String(data.target_user_id ?? data.targetUserId ?? '');
      if (!operation.profileId || profile !== operation.profileId) {
        return mismatch('网页关注目标与本次操作不一致');
      }
    } else {
      const note = data.note_id ?? data.noteId ?? data.note_oid ?? data.noteOid ?? data.note_ids;
      const matchesNote = Array.isArray(note)
        ? note.length === 1 && String(note[0]) === operation.noteId
        : String(note || '') === operation.noteId;
      if (!operation.noteId || !matchesNote) {
        return mismatch('网页互动所属笔记与本次操作不一致');
      }
    }
    if (operation.action === 'commentLike') {
      const target = String(data.comment_id ?? data.commentId ?? '');
      if (!operation.targetId || target !== operation.targetId) {
        return mismatch('网页点赞评论目标与本次操作不一致');
      }
    }
    if (operation.action === 'comment') {
      const target = String(data.target_comment_id ?? data.targetCommentId ?? '');
      if (String(data.content ?? '') !== operation.content || target !== operation.targetId) {
        return mismatch('网页评论内容或回复目标与本次操作不一致');
      }
    }
    if (!new RegExp('^/api/sns/web/v\\d+/' + suffix + '/?$').test(uri.pathname)) {
      if (operation.status === 'pending') {
        return mismatch('网页互动方向与本次操作不一致');
      }
      throw new Error('The opposite interaction is not authorized');
    }
    if (operation.sent) {
      // Never let a website retry turn an ambiguous result into duplicate text.
      throw new Error('This interaction has already been sent');
    }
    if (operation.status !== 'pending') throw new Error('This interaction is no longer active');
    operation.sent = true;
    return operation;
  };
  const settle = (operation, httpStatus, response) => {
    if (!operation) return;
    const success = httpStatus >= 200 && httpStatus < 300 && response?.success === true
      && (response.code === undefined || response.code === 0 || response.code === '0');
    if (success) return finish(operation, 'success', '', {httpStatus});
    const message = typeof response?.msg === 'string' ? response.msg
      : typeof response?.message === 'string' ? response.message : '';
    const rejected = httpStatus >= 400 || response?.success === false
      || (response?.code !== undefined && response.code !== 0 && response.code !== '0');
    finish(operation, rejected ? 'error' : 'unknown',
      message || (httpStatus === 401 || httpStatus === 403 ? '请在小红书网页重新登录或完成验证'
        : httpStatus === 461 || httpStatus === 471 ? '请打开小红书网页完成验证后再操作'
        : httpStatus === 429 ? '小红书操作频繁，请稍后再试'
        : rejected ? '小红书服务器拒绝了操作'
        : '没有收到可确认的服务端结果，请刷新检查后再操作'),
      {httpStatus, code: response?.code});
  };
  if (typeof window.fetch === 'function') {
    const originalFetch = window.fetch;
    window.fetch = function(input, init) {
      const context = this;
      const args = arguments;
      const url = typeof input === 'string' || input instanceof URL ? String(input) : input?.url;
      const method = init?.method || input?.method || 'GET';
      const send = (body) => {
        let operation;
        try { operation = observe(method, url, body); }
        catch (error) { return Promise.reject(error); }
        let request;
        try { request = originalFetch.apply(context, args); }
        catch (error) {
          if (operation) finish(operation, 'unknown', '请求结果未知，请刷新检查后再操作');
          throw error;
        }
        return Promise.resolve(request).then((response) => {
          if (operation) {
            try {
              response.clone().json().then((data) => settle(operation, response.status, data),
                () => settle(operation, response.status, null));
            } catch (_) { settle(operation, response.status, null); }
          }
          return response;
        }, (error) => {
          if (operation) finish(operation, 'unknown', '网络中断，结果未知，请刷新检查后再操作');
          throw error;
        });
      };
      if (init?.body !== undefined) return send(init.body);
      if (typeof input?.clone === 'function' && String(method).toUpperCase() === 'POST') {
        return Promise.resolve().then(() => input.clone().text()).then(send, (error) => {
          try { observe(method, url, undefined, true); } catch (_) {}
          throw error;
        });
      }
      return send(undefined);
    };
  }
  if (typeof XMLHttpRequest !== 'undefined') {
    const requests = new WeakMap();
    const originalOpen = XMLHttpRequest.prototype.open;
    const originalSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function(method, url) {
      requests.set(this, {method, url});
      return originalOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function(body) {
      const request = requests.get(this);
      const operation = request ? observe(request.method, request.url, body) : null;
      if (operation) {
        this.addEventListener('loadend', () => {
          if (this.status === 0) {
            finish(operation, 'unknown', '网络中断，结果未知，请刷新检查后再操作');
            return;
          }
          let response = null;
          try { response = this.responseType === 'json' ? this.response : JSON.parse(this.responseText); }
          catch (_) {}
          settle(operation, this.status, response);
        }, {once: true});
      }
      try { return originalSend.apply(this, arguments); }
      catch (error) {
        if (operation) finish(operation, 'unknown', '请求结果未知，请刷新检查后再操作');
        throw error;
      }
    };
  }
  bridge.begin = (spec) => {
    if (!spec || typeof spec.id !== 'string' || !spec.id
        || !['like', 'favorite', 'comment', 'follow', 'commentLike'].includes(spec.action)
        || typeof spec.value !== 'boolean') return false;
    if (spec.action === 'follow') {
      if (typeof spec.profileId !== 'string' || !spec.profileId) return false;
    } else if (typeof spec.noteId !== 'string' || !spec.noteId) return false;
    if (spec.action === 'commentLike'
        && (typeof spec.targetId !== 'string' || !spec.targetId)) return false;
    if (spec.action === 'comment' && (typeof spec.content !== 'string'
        || !spec.content.trim() || typeof spec.targetId !== 'string')) return false;
    if (bridge.pending?.id === spec.id) return false;
    if (bridge.pending?.status === 'pending') return false;
    bridge.pending = {...spec, status: 'pending', message: '', sent: false};
    return true;
  };
  bridge.result = (id) => {
    const operation = bridge.pending;
    if (!operation || operation.id !== id) return JSON.stringify({status: 'unknown', message: '页面已切换，操作结果未知'});
    return JSON.stringify({status: operation.status, message: operation.message,
      sent: operation.sent, httpStatus: operation.httpStatus, code: operation.code});
  };
  bridge.cancel = (id) => {
    if (bridge.pending?.id === id) finish(bridge.pending, 'unknown', '等待服务端确认超时，请刷新检查后再操作');
  };
  window.__mixsocialXhsInteraction = bridge;
  return true;
})()''';

String xhsBeginInteractionScript({
  required String operationId,
  required String noteId,
  required String action,
  bool value = false,
  String content = '',
  String targetId = '',
  String profileId = '',
}) =>
    'window.__mixsocialXhsInteraction.begin(${jsonEncode(<String, Object>{'id': operationId, 'noteId': noteId, 'action': action, 'value': value, 'content': content, 'targetId': targetId, 'profileId': profileId})})';

String xhsInteractionResultScript(String operationId) =>
    'window.__mixsocialXhsInteraction?.result(${jsonEncode(operationId)})'
    ' || JSON.stringify({status: "unknown", message: "页面已切换，操作结果未知"})';

String xhsCancelInteractionScript(String operationId) =>
    'window.__mixsocialXhsInteraction?.cancel(${jsonEncode(operationId)})';

String xhsCurrentInteractionStateScript(String noteId, String field) =>
    '''(() => {
  const unwrap = (value) => {
    for (let i = 0; i < 5 && value && typeof value === 'object'; i++) {
      if (value.__v_isRef === true || 'value' in value || '_value' in value || '_rawValue' in value) {
        value = value.value ?? value._value ?? value._rawValue;
      } else break;
    }
    return value;
  };
  const state = unwrap(window.__INITIAL_STATE__);
  const notes = unwrap(unwrap(state?.note)?.noteDetailMap);
  const detail = unwrap(notes?.[${jsonEncode(noteId)}]);
  const note = unwrap(detail?.note);
  const info = unwrap(note?.interactInfo ?? note?.interact_info);
  const value = unwrap(info?.[${jsonEncode(field)}]);
  return typeof value === 'boolean' ? String(value) : '';
})()''';

String xhsClickInteractionScript(String action) =>
    '''(() => {
  const selectors = ${jsonEncode(action == 'like' ? <String>['.interact-container .left .like-wrapper', '.interact-container .left .like-lottie', '.interact-container .like-wrapper'] : <String>['.interact-container .left .collect-wrapper', '.interact-container .left .collect-icon', '.interact-container .collect-wrapper'])};
  const element = selectors.map((selector) => document.querySelector(selector)).find(Boolean);
  if (!element) return false;
  const button = element.closest('button, [role="button"], .like-wrapper, .collect-wrapper') || element;
  if (button.disabled || button.getAttribute('aria-disabled') === 'true') return false;
  button.click();
  return true;
})()''';

String xhsFillCommentScript(String content) =>
    '''(() => {
  const placeholder = document.querySelector('.input-box .content-edit span, .comment-input-wrapper');
  if (placeholder) placeholder.click();
  const input = document.querySelector('.input-box .content-edit .content-input, '
    + '.input-box [contenteditable="true"], .comment-input-wrapper textarea, '
    + '.input-box textarea, #content-textarea');
  if (!input || input.disabled || input.readOnly) return false;
  input.focus();
  const content = ${jsonEncode(content)};
  if (input.tagName === 'TEXTAREA' || input.tagName === 'INPUT') {
    const prototype = input.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
    if (setter) setter.call(input, content); else input.value = content;
  } else input.textContent = content;
  input.dispatchEvent(new InputEvent('input', {bubbles: true, inputType: 'insertText', data: content}));
  return true;
})()''';

String xhsSubmitCommentInteractionScript({bool submit = true}) =>
    '''(() => {
  const button = document.querySelector('.input-box button.submit, div.bottom button.submit, '
    + '.comment-input-wrapper .send-btn, .comment-input-wrapper button[type="submit"]');
  if (!button || button.disabled || button.getAttribute('aria-disabled') === 'true'
      || button.classList.contains('disabled')) return false;
  ${submit ? 'button.click();' : ''}
  return true;
})()''';

String xhsSelectReplyTargetScript(String commentId) =>
    '''(() => {
  const id = ${jsonEncode(commentId)};
  const comment = document.getElementById('comment-' + id) || document.getElementById(id)
    || [...document.querySelectorAll('[data-comment-id]')].find((node) => node.getAttribute('data-comment-id') === id);
  if (!comment) return false;
  const button = comment.querySelector('.right > .interactions .reply, .interactions .reply, '
    + '[data-action="reply"], button.reply');
  if (!button) return false;
  button.scrollIntoView({block: 'center', behavior: 'auto'});
  button.click();
  return true;
})()''';
