// WebHome networking API. Only the selected top document receives this SDK;
// native code independently validates its frame, source, token and origin.
(() => {
  const config = window.__yingxiaHTMLHome;
  delete window.__yingxiaHTMLHome;
  if (!config || window.top !== window || location.origin !== config.origin || window.__yingxiaHomeSDK) return;
  window.__yingxiaHomeSDK = true;
  const channel = window.webkit.messageHandlers.localHTMLHome;
  const invoke = (method, payload = {}) => channel.postMessage({ token: config.token, method, payload });
  const absolute = input => {
    const url = new URL(String(input), document.baseURI || location.href);
    if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password)
      throw new Error('仅支持不含账号密码的 HTTP / HTTPS 地址');
    return url.href;
  };
  const unwrap = (input, options = {}) => {
    const value = new URL(String(input), document.baseURI || location.href);
    if (value.href.startsWith(config.resourceBase + '?')) return {
      ...options, url: absolute(value.searchParams.get('url')),
      headers: { ...JSON.parse(value.searchParams.get('headers') || '{}'), ...options.headers },
    };
    return { ...options, url: absolute(input) };
  };
  const resource = (input, options = {}) => {
    if (!input || /^(?:data:|blob:)/i.test(String(input))) return input;
    const request = unwrap(input, options);
    return config.resourceBase + '?' + new URLSearchParams({ url: request.url, headers: JSON.stringify(request.headers || {}) });
  };
  // WKURLSchemeHandler is a finite data/image gateway, not AVFoundation's
  // streaming loader. Existing HTML audio/video keeps the original HTTP CDN
  // path; native fm.play receives the resource headers through unwrap instead.
  const mediaSource = value => typeof value === 'string' && value.startsWith(config.resourceBase + '?') ? unwrap(value).url : value;
  for (const type of [typeof HTMLMediaElement === 'function' ? HTMLMediaElement : null,
    typeof HTMLSourceElement === 'function' ? HTMLSourceElement : null]) {
    if (!type) continue;
    const descriptor = Object.getOwnPropertyDescriptor(type.prototype, 'src');
    if (descriptor?.set) Object.defineProperty(type.prototype, 'src', { ...descriptor,
      set(value) { descriptor.set.call(this, mediaSource(value)); } });
    const setAttribute = type.prototype.setAttribute;
    type.prototype.setAttribute = function(name, value) {
      return setAttribute.call(this, name, String(name).toLowerCase() === 'src' ? mediaSource(value) : value);
    };
  }
  const request = async (url, options = {}) => {
    const payload = unwrap(url, options);
    // The supplied Jasna Mac adapter declares desktop Chrome, while this host
    // runs WebKit. Its Turnstile window and cookie-backed API retry must keep
    // the actual browser identity instead of impersonating a different engine.
    if (window.__ltxMacCat?.active && new URL(payload.url).origin === 'https://ltx.libray.workers.dev') {
      const values = Object.fromEntries(Object.entries(payload.headers || {}).filter(([name]) => name.toLowerCase() !== 'user-agent'));
      payload.headers = { ...values, 'User-Agent': navigator.userAgent };
    }
    const binary = options.responseType === 'arraybuffer';
    if (binary) payload.responseType = 'base64';
    const result = await invoke('net.request', payload);
    if (binary) result.body = Uint8Array.from(atob(result.body), char => char.charCodeAt(0)).buffer;
    return result;
  };
  const cache = {
    get: (key, rule) => invoke('cache.get', { key: String(key), rule }),
    set: (key, value, rule) => invoke('cache.set', { key: String(key), value, rule }),
    del: (key, rule) => invoke('cache.del', { key: String(key), rule }),
  };
  // Imported documents have an opaque WebKit storage origin. Keep their
  // familiar synchronous localStorage API with a bounded, source-scoped native store.
  if (config.localFile) {
    const values = new Map(Object.entries(config.cache || {}));
    const storage = {
      get length() { return values.size; }, key: index => [...values.keys()][index] ?? null,
      getItem: key => values.get(String(key)) ?? null,
      setItem(key, value) { key = String(key); value = String(value); values.set(key, value); void cache.set(key, value, '__localStorage').catch(() => {}); },
      removeItem(key) { key = String(key); values.delete(key); void cache.del(key, '__localStorage').catch(() => {}); },
      clear() { for (const key of [...values.keys()]) this.removeItem(key); },
    };
    Object.defineProperty(window, 'localStorage', { value: storage, configurable: true });
  }
  const viewport = () => ({ width: innerWidth, height: innerHeight, safeTop: 0, safeRight: 0, safeBottom: 0, safeLeft: 0,
    safeBottomMax: 0, gestureLeft: 0, gestureRight: 0, gestureBottom: 0, keyboardBottom: 0,
    statusBarHeight: 0, navigationBarHeight: 0, chromeMode: 'normal', systemBarsHidden: false });
  const ui = { getViewport: () => Promise.resolve(viewport()), setChrome: () => Promise.resolve(viewport()),
    setToolbar: () => Promise.resolve(viewport()), restoreChrome: () => Promise.resolve(viewport()) };
  const media = (url, options = {}) => /^data:application\/dash\+xml[;,]/i.test(String(url))
    ? { ...options, url: String(url) } : unwrap(url, options);
  let playbackGeneration = 0;
  let inlineSession = null;
  const resolutions = new Map();
  const headers = (...inputs) => {
    const values = new Map();
    for (let input of inputs) {
      if (typeof input === 'string') { try { input = JSON.parse(input); } catch { throw new Error('首页请求头无效'); } }
      for (const [name, value] of Object.entries(input || {})) values.set(name.toLowerCase(), [name, value]);
    }
    return Object.fromEntries(values.values());
  };
  const matchesEpisode = (item, episode) => item.name === episode.name
    && (item.pageUrl || item.url) === (episode.pageUrl || episode.url);
  window.__yingxiaCanResolveHTMLHomeEpisode = request => {
    if (typeof window.__fmWebHomeHistoryResolver === 'function') return true;
    if (!inlineSession) return typeof (window.__fmWebHomeInlineResolver || window.__fmYmvidResolveEpisode) === 'function';
    return inlineSession.workID === String(request.workID || '') && inlineSession.episodes.some(item => matchesEpisode(item, request.episode));
  };
  window.__yingxiaCancelHTMLHomeResolution = id => resolutions.get(String(id))?.();
  window.__yingxiaResolveHTMLHomeEpisode = async request => {
    const id = String(request.requestID || '');
    if (!id || resolutions.has(id)) throw new Error('首页续播请求无效');
    let cancel;
    const canceled = new Promise((_, reject) => { cancel = () => reject(new Error('首页续播解析已取消')); });
    resolutions.set(id, cancel);
    const operation = async () => {
      const episode = { ...request.episode, resolve: true };
      delete episode.mediaUrl;
      delete episode.audioUrl;
      let resolver = window.__fmWebHomeHistoryResolver;
      let baseHeaders = {};
      const explicitHistory = typeof resolver === 'function';
      if (!explicitHistory) {
        if (inlineSession) {
          if (inlineSession.workID !== String(request.workID || '')) throw new Error('首页播放列表已改变，无法使用其他影片的解析状态');
          const item = inlineSession.episodes.find(value => matchesEpisode(value, episode));
          if (!item) throw new Error('保存的这一集已不在首页播放列表中');
          resolver = inlineSession.resolver;
          baseHeaders = headers(inlineSession.header, inlineSession.headers, item.header, item.headers);
        } else {
          resolver = window.__fmWebHomeInlineResolver || window.__fmYmvidResolveEpisode;
          if (request.allowWait && typeof resolver !== 'function') {
            const deadline = Date.now() + 5000;
            while (typeof resolver !== 'function' && Date.now() < deadline && resolutions.has(id)) {
              await new Promise(resolve => setTimeout(resolve, 100));
              resolver = window.__fmWebHomeInlineResolver || window.__fmYmvidResolveEpisode;
            }
          }
        }
      }
      if (typeof resolver !== 'function') throw new Error('此 HTML 来源没有提供可恢复的逐集解析器，请在该来源重新选择影片');
      const resolved = await resolver(explicitHistory ? { ...request, episode } : episode);
      if (resolved?.error) throw new Error(resolved.error);
      if (!resolved || !(resolved.mediaUrl || resolved.url)) throw new Error('HTML 来源未返回可播放地址，原影片解析状态可能已失效');
      const normalized = media(resolved.mediaUrl || resolved.url, { ...resolved,
        headers: headers(baseHeaders, resolved.header, resolved.headers) });
      return { ...normalized, mediaUrl: normalized.url };
    };
    try { return await Promise.race([operation(), canceled]); }
    finally { resolutions.delete(id); }
  };
  const player = {
    playUrl: (url, title, options) => { playbackGeneration++; return invoke('player.playUrl', { ...media(url, options), title }); },
    playVod: (siteKey, vodId, title, pic, options) => { playbackGeneration++; return invoke('player.playVod', { ...options, siteKey, vodId, title, pic }); },
    playVodInline: async payload => {
      const generation = ++playbackGeneration;
      let episodes = payload.episodes || [];
      let index = Math.max(0, episodes.findIndex(item => item.name === payload.mark));
      for (const key of ['playIndex', 'episodeIndex', 'currentIndex', 'ep_index', 'startIndex', 'index', 'position']) {
        if (payload[key] === undefined || payload[key] === null || payload[key] === '') continue;
        index = Number(payload[key]);
        if (!Number.isInteger(index) || index < 0 || index >= episodes.length) throw new Error('首页选集序号无效');
        break;
      }
      const resolver = window.__fmWebHomeInlineResolver || window.__fmYmvidResolveEpisode;
      const originalEpisodes = episodes.map(item => ({ ...item, pageUrl: item.pageUrl || item.url,
        resolverURL: item.resolverURL || item.url }));
      const selected = episodes[index];
      if (selected && !selected.mediaUrl && selected.resolve !== false && typeof resolver === 'function') {
        const resolved = await resolver(selected);
        if (generation !== playbackGeneration) throw new Error('已取消上一次首页播放请求');
        if (resolved?.error) throw new Error(resolved.error);
        if (resolved?.mediaUrl || resolved?.url) episodes = episodes.map((item, i) => i === index ? { ...item, ...resolved,
          pageUrl: item.pageUrl || item.url, mediaUrl: resolved.mediaUrl || resolved.url,
          resolverURL: item.resolverURL || item.url,
          headers: { ...item.header, ...item.headers, ...resolved.header, ...resolved.headers }, resolve: false } : item);
      }
      inlineSession = typeof resolver === 'function' ? { workID: String(payload.vod_id || ''),
        resolver, episodes: originalEpisodes, header: payload.header, headers: payload.headers } : null;
      return invoke('player.playVodInline', { ...payload, episodes, playIndex: index });
    },
    preloadArtwork: () => Promise.resolve({}),
    control: action => {
      if (['stop', 'next', 'prev', 'previous'].includes(action)) playbackGeneration++;
      return invoke('player.control', { action });
    }, status: () => invoke('player.status'),
  };
  const app = { search: (keyword, options) => invoke('app.search', { ...options, keyword }) };
  for (const name of ['openVod', 'openLive', 'openKeep', 'openSetting', 'history']) app[name] = () => invoke('app.' + name);
  const pan = { check: items => invoke('pan.check', { items }), play: payload => { playbackGeneration++; return invoke('pan.play', payload); } };
  const navigation = { back: () => invoke('navigation.back'), reload: () => invoke('navigation.reload') };
  const ext = { info: () => Promise.resolve({ enabled: false, matched: 0, ready: 0 }),
    log: () => Promise.resolve({}), toast: message => invoke('ext.toast', { message }) };
  const publicInvoke = (method, payload = {}) => {
    if (method === 'net.request') { const { url, ...options } = payload; return request(url, options); }
    if (method === 'player.playUrl') { const { url, title, ...options } = payload; return player.playUrl(url, title, options); }
    if (method === 'player.playVodInline') return player.playVodInline(payload);
    if (method === 'player.playVod') { const { siteKey, vodId, title, pic, ...options } = payload; return player.playVod(siteKey, vodId, title, pic, options); }
    if (method === 'player.control') return player.control(payload.action);
    if (method === 'pan.play') return pan.play(payload);
    return invoke(method, payload);
  };
  window.fongmiClient = { mode: 'mobile', isLeanback: false };
  window.fongmiBridge = {
    invoke: (id, method, payload) => Promise.resolve().then(() => publicInvoke(method, JSON.parse(payload || '{}'))).then(
      result => window.fongmiNative?.resolve(id, result), error => window.fongmiNative?.reject(id, error.message)),
    resourceUrl: (url, options) => resource(url, JSON.parse(options || '{}')),
  };
  window.fongmi = { invoke: publicInvoke, net: { request, resourceUrl: resource }, cache, ui, player, app, pan, ext, navigation,
    browser: { open: url => invoke('browser.open', { url: absolute(url) }) },
    site: { info: () => invoke('site.info') }, device: { info: () => invoke('device.info') }, config: { info: () => invoke('config.info') } };
  window.fm = { req: request, res: resource, cache, ui, player, pan, ext, check: pan.check,
    play: player.playUrl, vod: player.playVod, vodInline: player.playVodInline, preloadArtwork: player.preloadArtwork,
    ctrl: player.control, stat: player.status, ...app, ...navigation,
    site: window.fongmi.site.info, device: window.fongmi.device.info, config: window.fongmi.config.info };
  const ready = () => {
    window.dispatchEvent(new CustomEvent('fmsdk'));
    window.dispatchEvent(new CustomEvent('fmviewport', { detail: viewport() }));
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ready, { once: true });
  else ready();
})();
