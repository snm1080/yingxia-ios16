import { createHash, createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { AppError } from './errors.mjs';
import { providerJson, providerRequest } from './provider-http.mjs';
import { normalizePanShare } from './home-library.mjs';

const hosts = { quark: /^pan\.q(?:u|o)ark\.cn$/, aliyun: /^(www\.)?(aliyundrive|alipan)\.com$/,
  baidu: /^pan\.baidu\.com$/, uc: /^drive\.uc\.cn$/, tianyi: /^cloud\.189\.cn$/,
  '123': /^(?:(?:www\.)?123(?:pan|684|685|865|912|592)\.(?:com|cn)|(?:[a-z0-9-]+\.)?share\.123(?:pan|684|685|865|912|592)\.(?:com|cn))$/,
  '115': /^(www\.)?(115|115cdn|anxia)\.com$/, guangya: /^(www\.)?guangyapan\.com$/, pikpak: /^(www\.)?(my)?pikpak\.com$/,
  xunlei: /^pan\.xunlei\.com$/, mobile: /^(?:(?:www\.)?(?:caiyun|yun)\.139\.com|caiyun\.feixin\.10086\.cn)$/ };
const userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36';
const flag = value => [true, 1, '1', 'true'].includes(value);
const description = { ok: '链接有效', bad: '链接已失效', locked: '需要提取码或提取码错误', unsupported: '暂不支持检测', uncertain: '暂时无法确认' };
const outcome = (state, summary = description[state]) => ({ state, summary });
function errorOutcome(message = '') {
  // Only provider error fields reach this classifier. Never echo diagnostics
  // that may contain share tokens, passwords or private account details.
  if (/验证码|人机验证|captcha|challenge/i.test(message)) return outcome('uncertain', '需要验证码，暂时无法确认');
  if (/too.?many|rate.?limit|频繁|限流|(?:^|\s)429(?:\s|$)/i.test(message)) return outcome('uncertain', '请求受限，请稍后重试');
  if (/登录|登陆|unauth|authentication|(?:access|refresh)[_ .-]?token|invalid[_ .-]?token|(?:^|\s)(?:401|403)(?:\s|$)/i.test(message)) return outcome('uncertain', '需要登录后确认');
  if (/提取码|访问码|密码|pass.?code|password|share.?pwd/i.test(message)) return outcome('locked');
  if (/分享.{0,12}(?:失效|取消|不存在|过期|删除)|链接.{0,12}(?:失效|不存在|过期)|share(?:[_ .-]?link)?[_ .-]?(?:not[_ .-]?found|deleted|cancel|expired|forbidden|disabled)|share[_ .-]?link.*(?:not.?found|cancel|expired)/i.test(message)) return outcome('bad');
  return outcome('uncertain');
}
function fileShareOutcome(data) {
  const code = data.error_code ?? data.errorCode ?? data.code;
  if (code !== undefined && Number(code) !== 0) {
    if ([9, 4002].includes(Number(code))) return errorOutcome('captcha_invalid');
    return errorOutcome([code, data.error, data.error_description, data.message].filter(Boolean).join(' '));
  }
  const status = String(data.share_status || '').toUpperCase();
  if (['DELETED', 'CANCELED', 'CANCELLED', 'EXPIRED', 'NOT_FOUND', 'SENSITIVE_RESOURCE', 'FORBIDDEN', 'ILLEGAL'].includes(status)) return outcome('bad');
  if (data.error || status && status !== 'OK') return errorOutcome([data.error, data.error_description, data.share_status_text, status].filter(Boolean).join(' '));
  return outcome(status === 'OK' || Array.isArray(data.files) && data.files.length > 0 ? 'ok' : 'uncertain');
}
function tianyiReply(body) {
  let data;
  try { data = JSON.parse(body); } catch { /* Tianyi also returns XML. */ }
  const xmlError = data ? undefined : body.match(/<error(?:\s[^>]*)?>([\s\S]*?)<\/error>/i)?.[1];
  const errorCode = String(data?.errorCode || data?.error_code || (Number(data?.res_code) !== 0 ? data?.res_code : '')
    || xmlError?.match(/<code>\s*([^<]*?)\s*<\/code>/i)?.[1] || '').trim();
  let error;
  if (/^(?:ShareInfoNotFound|ShareNotFound|FileNotFound|FolderNotFound|ShareExpiredError|ShareAuditNotPass)$/i.test(errorCode)) error = outcome('bad');
  else if (/^ErrorAccessCode$/i.test(errorCode)) error = outcome('locked');
  else if (errorCode || xmlError !== undefined || data?.res_code && Number(data.res_code) !== 0)
    error = errorOutcome([errorCode, data?.res_message || data?.message || xmlError?.match(/<message>([^<]*)<\/message>/i)?.[1] || ''].join(' '));
  return { error, protected: data ? flag(data.needAccessCode) : /<needAccessCode>\s*(?:1|true)\s*<\/needAccessCode>/i.test(body),
    exists: data ? /^[1-9]\d*$/.test(String(data.shareId || '')) || !!data.fileName
      : !/<error[\s>]/i.test(body) && /<shareId>[^<]+|<fileName>[^<]+/.test(body) };
}
const xunleiClientId = 'ZUBzD9J_XPXfn7f7', xunleiVersion = '1.10.0.2633', xunleiPackage = 'com.xunlei.browser';
function xunleiMeta(deviceId) {
  const timestamp = String(Date.now());
  let signature = xunleiClientId + xunleiVersion + xunleiPackage + deviceId + timestamp;
  for (const salt of ['uWRwO7gPfdPB/0NfPtfQO+71', 'F93x+qPluYy6jdgNpq+lwdH1ap6WOM+nfz8/V', '0HbpxvpXFsBK5CoTKam',
    'dQhzbhzFRcawnsZqRETT9AuPAJ+wTQso82mRv', 'SAH98AmLZLRa6DB2u68sGhyiDh15guJpXhBzI', 'unqfo7Z64Rie9RNHMOB',
    '7yxUdFADp3DOBvXdz0DPuKNVT35wqa5z0DEyEvf', 'RBG', 'ThTWPG5eC0UBqlbQ+04nZAptqGCdpv9o55A'])
    signature = createHash('md5').update(signature + salt).digest('hex');
  return { timestamp, captcha_sign: '1.' + signature, client_version: xunleiVersion, package_name: xunleiPackage };
}

// The anonymous Mobile cloud API uses an IV-prefixed AES-CBC envelope, as in
// webhtv's DriveMobileCrypto. This public protocol key is not a user credential.
const mobileKey = Buffer.from('PVGDwmcvfs1uV3d1');
function encryptMobile(value) {
  const iv = randomBytes(16), cipher = createCipheriv('aes-128-cbc', mobileKey, iv);
  return Buffer.concat([iv, cipher.update(JSON.stringify(value)), cipher.final()]).toString('base64');
}
function decryptMobile(bytes) {
  let text = bytes.toString().trim();
  if (text.startsWith('"')) text = JSON.parse(text);
  const encrypted = Buffer.from(text, 'base64');
  if (encrypted.length < 32 || encrypted.length % 16) throw Error('Invalid Mobile cloud response');
  const decipher = createDecipheriv('aes-128-cbc', mobileKey, encrypted.subarray(0, 16));
  return JSON.parse(Buffer.concat([decipher.update(encrypted.subarray(16)), decipher.final()]).toString());
}

// Local provider checks follow webhtv DriveCheckService's five-state contract,
// bounded concurrency, completed-result cache, and shared in-flight requests.
// Transport failures and ambiguous HTML never establish that a share is invalid.
export class PanLinkChecker {
  constructor(settings, { json = providerJson, bytes = providerRequest } = {}) {
    this.settings = settings; this.json = json; this.bytes = bytes;
    this.cache = new Map(); this.inflight = new Map(); this.queue = []; this.active = 0;
    this.xunleiDeviceId = randomBytes(16).toString('hex');
  }
  async check({ items, refresh = false }, signal, { enabled } = {}) {
    if (!Array.isArray(items) || !items.length || items.length > 20) throw new AppError('INVALID_ARGUMENT', '每批检测需要 1 至 20 条链接');
    const config = (await this.settings.private()).tmdb;
    signal?.throwIfAborted();
    if (enabled === false || enabled === undefined && config.panCheckLinks === false) return { enabled: false, items: [] };
    const normalized = items.map(item => {
      if (!item || typeof item.id !== 'string' || item.id.length > 128 || typeof item.diskType !== 'string') throw new AppError('INVALID_ARGUMENT', '检测链接无效');
      const share = normalizePanShare(item.url, item.password, item.diskType);
      if (!share) throw new AppError('INVALID_ARGUMENT', '检测链接无效');
      return { id: item.id, disk_type: item.diskType, url: share.url, password: share.password, input: share.input };
    });
    const results = await Promise.all(normalized.map(async item => ({ id: item.id, ...await this.checkOne(item, signal, refresh === true) })));
    return { enabled: true, items: results };
  }
  async checkOne(item, signal, refresh = false) {
    signal?.throwIfAborted();
    const key = createHash('sha256').update(JSON.stringify([item.disk_type, item.input, item.password])).digest('hex');
    const cached = this.cache.get(key);
    if (!refresh && cached && cached.until > Date.now()) return cached.value;
    this.cache.delete(key);
    let shared = this.inflight.get(key);
    if (!shared || shared.controller.signal.aborted) {
      shared = { controller: new AbortController(), users: 0, done: false };
      const entry = shared;
      entry.promise = (async () => {
        const release = await this.acquire(entry.controller.signal);
        try {
          entry.controller.signal.throwIfAborted();
          const value = await this.local(item, entry.controller.signal);
          const ttl = { ok: 3600_000, bad: 300_000, locked: 300_000, unsupported: 86400_000 }[value.state];
          if (ttl) this.cache.set(key, { value, until: Date.now() + ttl });
          while (this.cache.size > 1000) this.cache.delete(this.cache.keys().next().value);
          return value;
        } catch (error) {
          if (entry.controller.signal.aborted) throw error;
          return outcome('uncertain', error?.code === 'REQUEST_ABORTED' ? '检测超时，请稍后重试'
            : error?.code === 'PROVIDER_NETWORK' ? '网络连接失败，暂时无法确认' : description.uncertain);
        } finally { release(); }
      })().finally(() => {
        entry.done = true;
        if (this.inflight.get(key) === entry) this.inflight.delete(key);
      });
      this.inflight.set(key, entry);
    }
    const entry = shared;
    return new Promise((resolve, reject) => {
      entry.users++;
      let finished = false;
      const finish = (callback, value) => {
        if (finished) return;
        finished = true; signal?.removeEventListener('abort', abort);
        if (--entry.users === 0 && !entry.done) entry.controller.abort();
        callback(value);
      };
      const abort = () => finish(reject, signal.reason);
      signal?.addEventListener('abort', abort, { once: true });
      entry.promise.then(value => finish(resolve, value), error => finish(reject, error));
      if (signal?.aborted) abort();
    });
  }
  acquire(signal) {
    signal.throwIfAborted();
    return new Promise((resolve, reject) => {
      const start = () => {
        signal.removeEventListener('abort', abort);
        this.active++;
        resolve(() => { this.active--; this.queue.shift()?.start(); });
      };
      const waiting = { start };
      const abort = () => {
        const index = this.queue.indexOf(waiting);
        if (index >= 0) this.queue.splice(index, 1);
        reject(signal.reason);
      };
      if (this.active < 10) start();
      else { this.queue.push(waiting); signal.addEventListener('abort', abort, { once: true }); }
    });
  }
  async local(item, signal) {
    const type = item.disk_type;
    if (!hosts[type] || !/^https?:\/\//i.test(item.input)) return outcome('unsupported');
    const url = new URL(item.input);
    if (!hosts[type]?.test(url.hostname) || !['http:', 'https:'].includes(url.protocol) || url.port) return outcome('unsupported');
    const id = url.pathname.match(type === '123' ? /\/(?:s|123pan)\/([^/]+)/ : /\/s\/([^/]+)/)?.[1];
    const password = item.password;
    const options = { signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(8000)]) : AbortSignal.timeout(8000), timeoutMs: 8000, maxBytes: 1024 * 1024, label: '网盘检测', acceptHttpErrors: true };
    const json = (api, extra = {}) => this.json(api, { ...options, ...extra, headers: { 'User-Agent': userAgent, ...extra.headers } });
    const enc = encodeURIComponent;
    if (type === 'quark' || type === 'uc') {
      if (!id) return outcome('uncertain');
      const base = type === 'quark' ? 'https://drive-pc.quark.cn' : 'https://pc-api.uc.cn';
      const origin = type === 'quark' ? 'https://pan.quark.cn' : 'https://drive.uc.cn';
      const headers = { Origin: origin, Referer: origin + '/' };
      const token = await json(base + '/1/clouddrive/share/sharepage/token?pr=' + (type === 'quark' ? 'ucpro' : 'UCBrowser'), { headers, json: { pwd_id: id, passcode: password, support_visit_limit_private_share: true } });
      if (Number(token.code) === 41008) return outcome('locked');
      if ([41004, 41010, 41011, 41012].includes(Number(token.code))) return outcome('bad');
      if (!token.data?.stoken) return errorOutcome([token.code, token.message].join(' '));
      const data = await json(base + '/1/clouddrive/share/sharepage/detail?' + new URLSearchParams({ pwd_id: id, stoken: token.data.stoken, pr: type === 'quark' ? 'ucpro' : 'UCBrowser', ver: '2' }), { headers });
      if ([41004, 41006, 41010, 41011, 41012, 41019].includes(Number(data.code))) return outcome('bad');
      if (Number(data.code) === 41008) return outcome('locked');
      if (Number(data.code) !== 0 || !Array.isArray(data.data?.list)) return errorOutcome([data.code, data.message].join(' '));
      const share = data.data.share || {}, status = Number(share.status || 0);
      if (flag(data.data.is_expire)) return outcome('bad');
      if (![0, 1, 3].includes(status) || data.data.list.length === 0) return outcome('uncertain');
      return outcome('ok');
    }
    if (type === 'aliyun' && id) {
      const data = await json('https://api.aliyundrive.com/adrive/v3/share_link/get_share_by_anonymous?share_id=' + enc(id), { json: { share_id: id }, headers: { Origin: 'https://www.alipan.com', Referer: 'https://www.alipan.com/', 'x-canary': 'client=web,app=share,version=v2.3.1' } });
      if (data.code) return errorOutcome(data.code + ' ' + (data.message || ''));
      if (/forbidden|cancel|expired|illegal|invalid|disabled/i.test(data.share_status || '')) return outcome('bad');
      if (password || flag(data.has_pwd) || flag(data.has_password) || flag(data.need_pwd)) {
        const token = await json('https://api.aliyundrive.com/v2/share_link/get_share_token', { json: { share_id: id, share_pwd: password }, headers: { Origin: 'https://www.alipan.com', Referer: 'https://www.alipan.com/' } });
        if (token.code) return errorOutcome(token.code + ' ' + (token.message || ''));
        return outcome(typeof token.share_token === 'string' && token.share_token ? 'ok' : 'uncertain');
      }
      return outcome(data.share_name || data.share_title || data.file_count > 0 ? 'ok' : 'uncertain');
    }
    if (type === 'baidu') {
      const short = id ? (id.startsWith('1') ? id.slice(1) : id)
        : /^\/share\/init\/?$/.test(url.pathname) ? url.searchParams.get('surl') : '';
      if (!short) return outcome('uncertain');
      const headers = { Referer: item.input };
      // The password endpoint can accept passwords for deleted shares, and its
      // list endpoint can then return a login requirement. Only the dedicated
      // error page, never a filename or generic login copy, proves deletion.
      try {
        const page = (await this.bytes('https://pan.baidu.com/s/1' + enc(short), {
          ...options, headers: { 'User-Agent': userAgent, ...headers },
        })).toString();
        if (/<title>\s*百度网盘\s*[-－]\s*链接不存在\s*<\/title>/i.test(page)
          && /\bid\s*=\s*["']shareError["']/i.test(page)) return outcome('bad');
      } catch {
        signal?.throwIfAborted();
        // Protected shares redirect to the extraction-code page; an unreadable
        // page leaves the API checks below responsible for establishing status.
      }
      const verified = await json('https://pan.baidu.com/share/verify?' + new URLSearchParams({ surl: short, pwd: password }), { method: 'POST', body: new URLSearchParams({ pwd: password, vcode: '', vcode_str: '' }).toString(), headers: { ...headers, 'Content-Type': 'application/x-www-form-urlencoded' } });
      if ([-9, -12].includes(Number(verified.errno))) return outcome('locked');
      if ([-7, 105, 115, 117, 145].includes(Number(verified.errno))) return outcome('bad');
      if (Number(verified.errno) === -21) return outcome('uncertain', '需要登录后确认');
      if (Number(verified.errno) !== 0 || typeof verified.randsk !== 'string' || !verified.randsk)
        return errorOutcome([verified.errno, verified.err_msg, verified.show_msg, verified.message].filter(Boolean).join(' '));
      // Baidu already escapes this cookie value. Escaping it again invalidates it.
      headers.Cookie = 'BDCLND=' + verified.randsk;
      const data = await json('https://pan.baidu.com/share/list?' + new URLSearchParams({ web: '1', page: '1', num: '20', shorturl: short, root: '1', clienttype: '0' }), { headers });
      if ([-9, -12].includes(Number(data.errno))) return outcome('locked');
      if ([-7, 105, 115, 117, 145].includes(Number(data.errno))) return outcome('bad');
      if (Number(data.errno) === -21) return outcome('uncertain', '需要登录后确认');
      if (Number(data.errno) !== 0) return errorOutcome([data.errno, data.err_msg, data.show_msg, data.message].filter(Boolean).join(' '));
      return outcome(Array.isArray(data.list) && data.list.length ? 'ok' : 'uncertain');
    }
    if (type === '115' && id) {
      if (!password) return outcome('locked');
      const data = await json('https://115cdn.com/webapi/share/snap?' + new URLSearchParams({ share_code: id, receive_code: password, offset: '0', limit: '20', cid: '' }));
      if (!flag(data.state) || Number(data.errno) !== 0) return errorOutcome(data.error || data.message || '');
      const share = data.data?.shareinfo || {}, state = Number(data.data?.share_state ?? share.share_state);
      if (state === 7) return outcome('bad');
      if (share.forbid_reason) return errorOutcome(share.forbid_reason);
      return outcome(state === 1 || data.data?.list?.length || share.share_title ? 'ok' : 'uncertain');
    }
    if (type === '123' && id) {
      // 123pan.com now serves a landing/404 page at the old API paths. Share
      // keys from its aliases and custom domains use the current web API.
      const base = 'https://www.123865.com/b/api/share/';
      const data = await json(base + 'info?shareKey=' + enc(id));
      if (Number(data.code) !== 0 || !data.data) return errorOutcome([data.code, data.message].join(' '));
      const share = data.data;
      if (flag(share.Expired)) return outcome('bad');
      if (flag(share.HasPwd)) {
        if (!password) return outcome('locked');
        const files = await json(base + 'get?' + new URLSearchParams({ shareKey: id, SharePwd: password, limit: '1', next: '0', orderBy: 'file_name', orderDirection: 'asc', ParentFileId: '0', Page: '1' }));
        if (Number(files.code) !== 0) return errorOutcome([files.code, files.message].join(' '));
        return outcome(Array.isArray(files.data?.InfoList) && files.data.InfoList.length ? 'ok' : 'uncertain');
      }
      return outcome(share.ShareKey === id || share.ShareName ? 'ok' : 'uncertain');
    }
    if (type === 'tianyi') {
      const code = url.searchParams.get('code') || url.pathname.match(/\/t\/([^/]+)/)?.[1];
      if (!code) return outcome('uncertain');
      const read = async (path, parameters) => tianyiReply((await this.bytes('https://cloud.189.cn/api/open/share/' + path + '?' + new URLSearchParams(parameters),
        { ...options, headers: { Referer: item.input, 'sign-type': '1', Accept: 'application/json;charset=UTF-8' } })).toString());
      const share = await read('getShareInfoByCodeV2.action', { shareCode: code });
      if (share.error && share.error.state !== 'locked') return share.error;
      if (share.protected || share.error?.state === 'locked') {
        if (!password) return outcome('locked');
        const verified = await read('checkAccessCode.action', { shareCode: code, accessCode: password });
        return verified.error || outcome(verified.exists ? 'ok' : 'uncertain');
      }
      return outcome(share.exists ? 'ok' : 'uncertain');
    }
    if (type === 'xunlei' && id) {
      const clientHeaders = { 'x-client-id': xunleiClientId, 'x-device-id': this.xunleiDeviceId, 'x-client-version': xunleiVersion };
      const challenge = await json('https://xluser-ssl.xunlei.com/v1/shield/captcha/init', { headers: clientHeaders,
        json: { action: 'get:/drive/v1/share', captcha_token: '', client_id: xunleiClientId, device_id: this.xunleiDeviceId,
          meta: xunleiMeta(this.xunleiDeviceId), redirect_uri: 'xlaccsdk01://xunlei.com/callback?state=harbor' } });
      if (typeof challenge.captcha_token !== 'string' || !challenge.captcha_token) return outcome('uncertain');
      const data = await json('https://api-pan.xunlei.com/drive/v1/share?' + new URLSearchParams({ share_id: id, pass_code: password, limit: '1', pass_code_token: '', page_token: '', thumbnail_size: 'SIZE_SMALL' }),
        { headers: { ...clientHeaders, 'x-captcha-token': challenge.captcha_token, Origin: 'https://pan.xunlei.com', Referer: 'https://pan.xunlei.com/' } });
      return fileShareOutcome(data);
    }
    if (type === 'guangya' && id) {
      const headers = { Origin: 'https://www.guangyapan.com', Referer: 'https://www.guangyapan.com/', Did: this.xunleiDeviceId, Dt: '4' };
      const token = await json('https://api.guangyapan.com/userres/v1/get_share_access_token', { headers, json: { shareId: id, ...(password ? { code: password } : {}) } });
      if (Number(token.code || 0) !== 0 || !token.data?.accessToken) return errorOutcome([token.code, token.msg || token.message].join(' '));
      const files = await json('https://api.guangyapan.com/userres/v1/get_share_page_files_list', { headers,
        json: { accessToken: token.data.accessToken, parentId: '', pageSize: 1, orderBy: 0, sortType: 0 } });
      if (Number(files.code || 0) !== 0) return errorOutcome([files.code, files.msg || files.message].join(' '));
      return outcome(Array.isArray(files.data?.list) && files.data.list.length ? 'ok' : 'uncertain');
    }
    if (type === 'pikpak' && id) {
      // The util's Android client supports an unsigned anonymous handshake;
      // no account token, sign-in, restore or user-drive operation is needed.
      const clientId = 'YNxT9w7GMdWvEOKa';
      const headers = { 'X-Client-Id': clientId, 'X-Device-Id': this.xunleiDeviceId, 'X-SDK-Version': '2.0.6.206003', 'X-Protocol-Version': '301' };
      const challenge = await json('https://user.mypikpak.com/v1/shield/captcha/init', { headers,
        json: { client_id: clientId, action: 'GET:/drive/v1/share', device_id: this.xunleiDeviceId, meta: {} } });
      if (typeof challenge.captcha_token !== 'string' || !challenge.captcha_token) return errorOutcome([challenge.error, challenge.error_description].join(' '));
      const result = await json('https://api-drive.mypikpak.com/drive/v1/share?' + new URLSearchParams({ share_id: id, pass_code: password, parent_id: '', limit: '1', thumbnail_size: 'SIZE_SMALL', order: '3' }),
        { headers: { ...headers, 'X-Captcha-Token': challenge.captcha_token } });
      const data = result.data && typeof result.data === 'object' && !Array.isArray(result.data) ? { ...result, ...result.data } : result;
      return fileShareOutcome(data);
    }
    if (type === 'mobile') {
      const shareId = url.pathname.match(/\/w\/i\/([^/]+)/)?.[1] || url.hash.match(/^#\/w\/i\/([^/?&#]+)/)?.[1]
        || (url.pathname === '/m/i' ? url.searchParams.get('linkID') || url.searchParams.get('linkId') || url.search.slice(1).split('&')[0] : '')
        || (url.hostname === 'caiyun.feixin.10086.cn' ? url.pathname.split('/')[1] : '');
      if (!shareId || !/^[a-zA-Z0-9_-]+$/.test(shareId)) return outcome('uncertain');
      const body = encryptMobile({ getOutLinkInfoReq: { account: '', linkID: shareId, passwd: password, caSrt: 1, coSrt: 1, srtDr: 0, bNum: 1, pCaID: 'root', eNum: 200 }, commonAccountInfo: { account: '', accountType: 1 } });
      const data = decryptMobile(await this.bytes('https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/IOutLink/getOutLinkInfoV6', { ...options, json: body,
        headers: { 'User-Agent': userAgent, Accept: 'application/json, text/plain, */*', 'hcy-cool-flag': '1',
          'x-deviceinfo': '||3|12.27.0|chrome|131.0.0.0|5c7c68368f048245e1ce47f1c0f8f2d0||windows 10|1536X695|zh-CN|||' } }));
      if (String(data.resultCode) !== '0' || data.success === false) return errorOutcome(data.desc || data.message || '');
      const share = data.data;
      return outcome(share && (share.lkName || Number(share.nodNum) > 0 || share.caLst?.length || share.coLst?.length) ? 'ok' : 'uncertain');
    }
    return outcome('unsupported');
  }
}
