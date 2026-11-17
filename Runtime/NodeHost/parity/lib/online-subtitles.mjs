import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash, randomUUID } from 'node:crypto';
import { gunzipSync, inflateRawSync } from 'node:zlib';
import { atomicWrite, JsonStore } from './files.mjs';
import { AppError, requireText } from './errors.mjs';
import { providerJson, providerRequest } from './provider-http.mjs';
import { fetchBuffer } from './http.mjs';
import { episodeNumbers, episodePreferenceKey } from './media-identity.mjs';
import { subtitleSearchQuery } from './subtitle-query.mjs';
import { tmdbSourceYear } from './tmdb-matching.mjs';
import { remoteShooterHash } from './subtitle-remote-hash.mjs';
import { searchSubtitleWebsite, subtitleCatDownload, subHDDownload } from './subtitle-web-providers.mjs';

const LIMIT = 8 * 1024 ** 2;
const ext = (name) => String(name).match(/\.(srt|ass|ssa|vtt)(?:$|\?)/i)?.[1]?.toLowerCase() || 'srt';
const endpoints = { xunlei: 'https://api-shoulei-ssl.xunlei.com/oracle/subtitle', assrt: 'https://api.assrt.net/v1', shooter: 'https://www.shooter.cn/api/subapi.php', subtitlecat: 'https://www.subtitlecat.com', subhd: 'https://subhd.tv' };
const browserHeaders = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36' };
const retryableDownloadErrors = new Set(['NETWORK_ERROR', 'REQUEST_ABORTED', 'DOWNLOAD_INTERRUPTED', 'HTTP_ERROR']);

function subtitleTextBytes(bytes) {
  // Some services decode a UTF-16 file as UTF-8, replacing its FF FE header
  // and other bytes with U+FFFD. The original text is unrecoverable.
  if (bytes.subarray(0, 6).equals(Buffer.from('\ufffd\ufffd')) && bytes.subarray(6, 200).includes(0))
    throw new AppError('SUBTITLE_ENCODING', '字幕服务返回的文件编码已损坏，请选择另一份字幕');
  if (bytes[0] === 0xff && bytes[1] === 0xfe || bytes[0] === 0xfe && bytes[1] === 0xff) {
    try { bytes = Buffer.from(new TextDecoder(bytes[0] === 0xff ? 'utf-16le' : 'utf-16be', { fatal: true }).decode(bytes)); }
    catch { throw new AppError('SUBTITLE_ENCODING', '字幕文件编码已损坏，请选择另一份字幕'); }
  }
  const opening = bytes.subarray(0, 512).toString('utf8');
  if (/^\s*\[V4\+? Styles\]/i.test(opening)) {
    const type = /\[V4\+ Styles\]/i.test(opening) ? 'v4.00+' : 'v4.00';
    bytes = Buffer.concat([Buffer.from(`[Script Info]\nScriptType: ${type}\n`), bytes]);
  }
  return bytes;
}

export function assrtFileURL(value) {
  try {
    const url = new URL(value);
    if (url.protocol === 'http:' && /^file\d*\.assrt\.net$/i.test(url.hostname) && !url.port) {
      url.protocol = 'https:'; return url.toString();
    }
  } catch { /* validation is performed before fetching */ }
  return value;
}

export function shooterResponse(bytes) {
  // The legacy endpoint returns signed byte -1 (FF), even with format=json,
  // when the media fingerprint has no matches.
  if (bytes.length === 1 && bytes[0] === 0xff) return [];
  const text = bytes.toString('utf8').replace(/^\uFEFF/, '').trim();
  // This legacy endpoint also uses an empty body or a numeric status for a
  // fingerprint with no match. Neither is a malformed search result.
  if (!text || /^(?:-1|0|null)$/.test(text)) return [];
  let data;
  try { data = JSON.parse(text); }
  catch { throw new AppError('SUBTITLE_PROVIDER', /<(?:!doctype|html|head|body)\b/i.test(text)
    ? '射手字幕服务返回了网页，暂时无法查询；可使用其他字幕来源或稍后重试'
    : '射手字幕服务响应不完整，请稍后重试'); }
  if (!Array.isArray(data)) throw new AppError('SUBTITLE_PROVIDER', '射手字幕服务暂不可用，请稍后重试');
  return data.filter(group => group && typeof group === 'object' && Array.isArray(group.Files));
}

async function assrtJson(url, options) {
  const data = await providerJson(url, { ...options, acceptHttpErrors: true });
  if (data?.status === 0) return data;
  const messages = {
    1: 'Token 对应的用户不存在，请检查 Assrt 账户',
    101: '搜索关键词太短，请输入更完整的片名',
    20000: '请求缺少必要参数',
    20001: 'Token 无效，请在设置中重新填写 Assrt Token',
    20400: '字幕接口不存在',
    20900: '字幕已不存在，请重新搜索',
    30000: '服务暂时异常，请稍后重试',
    30001: '数据库暂时不可用，请稍后重试',
    30002: '搜索引擎暂时不可用，请稍后重试',
    30300: '服务暂时不可用，请稍后重试',
    30900: '请求配额已用完，请稍后重试（默认每分钟 20 次，Token 和 IP 共享）',
  };
  const status = Number.isInteger(data?.status) ? data.status : null;
  throw new AppError('SUBTITLE_PROVIDER', `Assrt ${messages[status] || '返回了无效响应，请稍后重试'}${status === null ? '' : `（错误 ${status}）`}`);
}

function assrtCandidate(item) {
  // Live search responses can mix the documented API schema and site-index rows.
  const id = item?.id ?? item?.fileid;
  if (!/^[1-9]\d*$/.test(String(id))) return [];
  const subtype = String(item.m_subtype || item.subtype || '');
  const format = subtype.match(/\b(srt|ass|ssa|vtt|sup|idx|sub)\b/i)?.[1]?.toLowerCase()
    || (/vobsub/i.test(subtype) ? 'vobsub' : ext(item.filename || item.sub_name));
  return [{ assrtId: String(id),
    name: item.native_name || item.video_chinese_name || item.m_video_chinese_name || item.m_title || item.videoname || item.m_videoname || item.filename || item.sub_name || '字幕',
    language: String(item.lang?.desc || item.m_lang || (item.lang?.langlist?.langchs ? 'zh' : '')).replace(/&nbsp;|&#160;/gi, ' ').trim(),
    format,
  }];
}

export function subtitleFiles(bytes, name = 'subtitle.srt', format = '') {
  if (bytes.length < 4) throw new AppError('SUBTITLE_FORMAT', '字幕文件为空或已截断');
  if (bytes.length > LIMIT) throw new AppError('SUBTITLE_LIMIT', '字幕文件超过 8 MiB');
  if (bytes[0] === 0x1f && bytes[1] === 0x8b) bytes = gunzipSync(bytes, { maxOutputLength: LIMIT });
  if (bytes.subarray(0, 6).equals(Buffer.from('Rar!\x1a\x07', 'binary')))
    throw new AppError('SUBTITLE_ARCHIVE', '暂不支持直接解压 RAR 字幕，请选择含 SRT、ASS、SSA 或 VTT 文件的结果');
  if (bytes.readUInt32LE(0) !== 0x04034b50) {
    // Providers often return a display title without a filename extension.
    // Validate both their declared format and binary signatures before caching.
    const unsupported = bytes.subarray(0, 2).toString('ascii') === 'PG' ? 'SUP'
      : bytes.subarray(0, 4).equals(Buffer.from([0, 0, 1, 0xba])) ? 'VobSub'
      : bytes.subarray(0, 6).equals(Buffer.from([0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c])) ? '7z'
      : String(format).match(/^(7z|sup|pgs|idx|sub|vobsub)$/i)?.[1] || String(name).match(/\.(7z|sup|idx|sub)$/i)?.[1];
    if (unsupported) throw new AppError('SUBTITLE_FORMAT', `暂不支持 ${unsupported.toUpperCase()} 字幕，请选择 SRT、ASS、SSA 或 VTT`);
    return [{ name: path.basename(name), bytes: subtitleTextBytes(bytes) }];
  }
  let end = -1;
  for (let i = bytes.length - 22; i >= Math.max(0, bytes.length - 65557); i--) if (bytes.readUInt32LE(i) === 0x06054b50) { end = i; break; }
  if (end < 0) throw new AppError('SUBTITLE_ARCHIVE', '字幕 ZIP 无效');
  const count = bytes.readUInt16LE(end + 10);
  let cursor = bytes.readUInt32LE(end + 16), total = 0;
  if (count > 200) throw new AppError('SUBTITLE_LIMIT', '字幕压缩包文件过多');
  const files = [];
  for (let index = 0; index < count; index++) {
    if (cursor + 46 > bytes.length || bytes.readUInt32LE(cursor) !== 0x02014b50) throw new AppError('SUBTITLE_ARCHIVE', '字幕 ZIP 目录无效');
    const flags = bytes.readUInt16LE(cursor + 8), method = bytes.readUInt16LE(cursor + 10);
    const size = bytes.readUInt32LE(cursor + 20), plainSize = bytes.readUInt32LE(cursor + 24);
    const nameLength = bytes.readUInt16LE(cursor + 28), extra = bytes.readUInt16LE(cursor + 30), comment = bytes.readUInt16LE(cursor + 32);
    const offset = bytes.readUInt32LE(cursor + 42);
    const filename = bytes.subarray(cursor + 46, cursor + 46 + nameLength).toString('utf8');
    cursor += 46 + nameLength + extra + comment;
    if (!/\.(srt|ass|ssa|vtt)$/i.test(filename) || /(^|[\\/])\.\.([\\/]|$)|^[\\/]/.test(filename)) continue;
    if (flags & 1 || ![0, 8].includes(method) || plainSize > LIMIT || offset + 30 > bytes.length || bytes.readUInt32LE(offset) !== 0x04034b50)
      throw new AppError('SUBTITLE_ARCHIVE', '字幕 ZIP 不支持加密、超大文件或此压缩格式');
    const start = offset + 30 + bytes.readUInt16LE(offset + 26) + bytes.readUInt16LE(offset + 28);
    if (start + size > bytes.length) throw new AppError('SUBTITLE_ARCHIVE', '字幕 ZIP 已截断');
    const compressed = bytes.subarray(start, start + size);
    const value = method === 8 ? inflateRawSync(compressed, { maxOutputLength: LIMIT }) : compressed;
    total += value.length;
    if (value.length !== plainSize || total > LIMIT) throw new AppError('SUBTITLE_LIMIT', '字幕解压超过大小限制');
    files.push({ name: path.basename(filename.replaceAll('\\', '/')), bytes: subtitleTextBytes(value) });
  }
  if (!files.length) throw new AppError('SUBTITLE_FORMAT', '压缩包没有 SRT、ASS、SSA 或 VTT 字幕');
  return files;
}

export async function shooterHash(file) {
  const handle = await fs.open(file, 'r');
  try {
    const size = (await handle.stat()).size;
    if (size < 12288) return '';
    const parts = [];
    for (const position of [4096, Math.floor(size / 3) * 2, Math.floor(size / 3), size - 8192]) {
      const data = Buffer.alloc(4096); const read = await handle.read(data, 0, 4096, position);
      if (read.bytesRead !== 4096) return '';
      parts.push(createHash('md5').update(data).digest('hex'));
    }
    return parts.join(';');
  } finally { await handle.close(); }
}

export class OnlineSubtitles {
  constructor(directory, settings, current, options = {}) {
    this.directory = path.join(directory, 'subtitles'); this.settings = settings; this.current = current;
    this.endpoints = { ...endpoints, ...options.endpoints }; this.job = null;
    this.downloads = new JsonStore(path.join(this.directory, 'downloads.json'), { assets: {} });
  }
  session({ sessionId, mediaVersion }) {
    const session = this.current();
    if (!session || session.id !== sessionId || mediaVersion !== undefined && mediaVersion !== (session.mediaVersion || 0))
      throw new AppError('SUBTITLE_STALE', '播放媒体已改变');
    return session;
  }
  location(asset) {
    // Only files written to our subtitle cache may be deleted, never arbitrary local subtitles.
    const location = path.resolve(this.directory, asset.file);
    if (path.dirname(location) !== path.resolve(this.directory) || !/^[a-f0-9-]+\.(srt|ass|ssa|vtt)$/i.test(asset.file))
      throw new AppError('SUBTITLE_PATH', '字幕缓存路径无效');
    return location;
  }
  async list(params) {
    const session = this.session(params), episode = episodePreferenceKey(session.request || {});
    // Retain access to the remembered download created by older versions.
    const remembered = session.preferences?.subtitle;
    if (remembered?.url && path.dirname(path.resolve(remembered.url)) === path.resolve(this.directory)) {
      const file = path.basename(remembered.url);
      if (/^[a-f0-9-]+\.(srt|ass|ssa|vtt)$/i.test(file) && await fs.stat(remembered.url).then(s => s.isFile(), () => false)) {
        await this.downloads.update(data => {
          if (!Object.values(data.assets).some(asset => asset.episode === episode && asset.file === file)) {
            const id = randomUUID(); data.assets[id] = { id, episode, file, name: remembered.name || file, candidateKey: '', provider: '已下载' };
          }
        });
      }
    }
    const data = await this.downloads.read(), files = [];
    for (const asset of Object.values(data.assets).filter(asset => asset.episode === episode)) {
      const location = this.location(asset);
      if (await fs.stat(location).then(s => s.isFile(), () => false))
        files.push({ id: asset.id, name: asset.name, candidateKey: asset.candidateKey, provider: asset.provider, path: location });
    }
    this.session(params);
    return { files, selectedId: files.find(file => file.path === remembered?.url)?.id || null };
  }
  cancel() { this.job?.controller.abort(); this.job = null; }
  check(job) {
    if (this.job !== job || job.controller.signal.aborted || this.current() !== job.session || (job.session.mediaVersion || 0) !== job.mediaVersion)
      throw new AppError('SUBTITLE_STALE', '媒体或字幕搜索已改变，请重新搜索');
  }
  async assrtDownloads(item, signal, timeoutMs) {
    const config = (await this.settings.private()).subtitles;
    const endpoint = new URL(this.endpoints.assrt + '/sub/detail');
    endpoint.searchParams.set('token', config.assrtToken); endpoint.searchParams.set('id', String(item.assrtId));
    const data = await assrtJson(endpoint, { signal, timeoutMs, label: 'Assrt 字幕详情' });
    const first = data.sub?.subs?.[0];
    if (!first) throw new AppError('SUBTITLE_MISSING', '字幕下载地址不可用');
    const downloads = (first.filelist || []).filter(file => /^https?:\/\//i.test(file.url || '') && /\.(srt|ass|ssa|vtt)$/i.test(file.f || file.filename || file.name || ''))
      .slice(0, 100).map(file => ({ url: assrtFileURL(file.url), name: file.f || file.filename || file.name }));
    return downloads.length ? downloads : [{ url: assrtFileURL(first.url), name: first.filename || item.name, format: item.format }];
  }
  async search({ sessionId, mediaVersion, query, language }, signal) {
    const session = this.session({ sessionId, mediaVersion });
    this.cancel();
    const job = { id: randomUUID(), controller: new AbortController(), session, mediaVersion: session.mediaVersion || 0, candidates: new Map() };
    this.job = job;
    const combined = signal ? AbortSignal.any([signal, job.controller.signal]) : job.controller.signal;
    const config = (await this.settings.private()).subtitles;
    const text = requireText(query || subtitleSearchQuery(session), '字幕片名', 300);
    const tasks = [];
    const add = (provider, action) => tasks.push(action().then((items) => ({ provider, items, state: 'complete' })).catch((error) => {
      const unavailable = provider === 'shooter' && ['SUBTITLE_RANGE', 'SUBTITLE_MEDIA'].includes(error.code);
      return { provider, items: [], state: unavailable ? 'unavailable' : 'error', code: error.code,
        ...(unavailable ? { warning: error.message } : { error: error.message }) };
    }));
    if (config.xunlei) add('xunlei', async () => {
      const url = new URL(this.endpoints.xunlei); url.searchParams.set('name', text);
      const data = await providerJson(url, { signal: combined, label: '迅雷字幕', headers: { ...browserHeaders, Referer: 'https://sl-m-ssl.xunlei.com/' } });
      if (data.code !== 0 || !Array.isArray(data.data)) throw new AppError('SUBTITLE_PROVIDER', '迅雷字幕未返回有效结果');
      return data.data.filter((item) => item.url).map((item) => ({ name: item.name || item.extra_name || '字幕', url: item.url,
        language: Array.isArray(item.languages) ? item.languages.join('/') : String(item.language || ''), format: item.ext || ext(item.name), score: Number(item.score) || 0 }));
    });
    if (config.assrt && config.assrtToken) add('assrt', async () => {
      const url = new URL(this.endpoints.assrt + '/sub/search');
      for (const [key, value] of Object.entries({ token: config.assrtToken, q: text, cnt: '15' })) url.searchParams.set(key, value);
      const data = await assrtJson(url, { signal: combined, label: 'Assrt 字幕' });
      // Assrt returns an empty object, not an array, when a search has no matches.
      const subs = data.sub?.subs;
      const items = Array.isArray(subs) ? subs : subs && typeof subs === 'object' && !Object.keys(subs).length ? [] : null;
      if (!items) throw new AppError('SUBTITLE_PROVIDER', 'Assrt 返回了无效的字幕列表，请稍后重试');
      return items.flatMap(assrtCandidate);
    });
    const quality = session.qualities?.[session.qualityIndex || 0];
    const media = quality?.originalUrl || quality?.url || session.request?.direct;
    let segmented = /^(?:m3u8|hls|mpd|dash)$/i.test(quality?.format || '');
    if (media) {
      try {
        const parsed = new URL(media);
        segmented ||= /\.(?:m3u8|mpd)$/i.test(parsed.pathname);
        if (/\/(?:proxy|m3u8-clean)\/?$/i.test(parsed.pathname)) {
          segmented ||= /^(?:m3u8|hls|mpd|dash)$/i.test(parsed.searchParams.get('type') || parsed.searchParams.get('format') || '');
          for (const name of ['url', 'source']) {
            try { segmented ||= /\.(?:m3u8|mpd)$/i.test(new URL(parsed.searchParams.get(name)).pathname); } catch { /* no nested media address */ }
          }
        }
      } catch { segmented ||= /\.(?:m3u8|mpd)$/i.test(media); }
    }
    if (config.shooter && (!media || session.isLive || session.request?.isLive || segmented)) {
      tasks.push(Promise.resolve({ provider: 'shooter', items: [], state: 'skipped', code: 'SUBTITLE_MEDIA',
        warning: segmented ? '当前视频使用分片播放，射手需要完整视频文件的指纹；可选择其他字幕来源'
          : session.isLive || session.request?.isLive ? '直播没有固定视频文件指纹，射手无法匹配；可选择其他字幕来源'
            : '尚未取得视频文件地址，射手无法匹配；视频就绪后可重试' }));
    } else if (config.shooter) add('shooter', async () => {
      const remote = /^https?:/i.test(media);
      if (!remote && /^[a-z][a-z\d+.-]*:/i.test(media) && !media.startsWith('file:'))
        throw new AppError('SUBTITLE_MEDIA', '当前播放地址不是可读取的视频文件，射手无法匹配；可选择其他字幕来源');
      const file = remote ? new URL(media).pathname : media.startsWith('file:') ? fileURLToPath(media) : media;
      const filehash = remote ? await remoteShooterHash(media, quality?.originalUrl ? quality.originalHeaders || quality.headers : quality?.headers, combined) : await shooterHash(file);
      if (!filehash) return [];
      const body = new URLSearchParams({ filehash, pathinfo: path.basename(file), format: 'json', lang: (language || config.language).startsWith('en') ? 'eng' : 'chn' });
      const data = shooterResponse(await providerRequest(this.endpoints.shooter, { signal: combined, label: '射手字幕', method: 'POST', body,
        headers: { ...browserHeaders, Accept: 'application/json', 'Content-Type': 'application/x-www-form-urlencoded' } }));
      if (!Array.isArray(data)) return [];
      return data.flatMap((group) => group.Files
        .filter(entry => typeof entry?.Link === 'string' && /^https?:\/\//i.test(entry.Link))
        .map((entry) => ({ name: group.Desc || `${path.basename(file)}.${entry.Ext || 'srt'}`, url: entry.Link, format: entry.Ext, language: language || config.language, score: 100 })));
    });
    for (const provider of ['subtitlecat', 'subhd']) if (config[provider]) add(provider, () => searchSubtitleWebsite(provider, this.endpoints[provider], text, combined));
    const results = await Promise.all(tasks); this.check(job);
    const items = [], seen = new Set();
    for (const result of results) for (const candidate of result.items.slice(0, 60)) {
      const key = result.provider + (candidate.assrtId || candidate.url);
      if (seen.has(key)) continue; seen.add(key);
      const id = randomUUID();
      const candidateKey = createHash('sha256').update(key).digest('hex');
      job.candidates.set(id, { ...candidate, candidateKey, provider: result.provider });
      const numbers = episodeNumbers(candidate.name), identity = session.identity;
      const conflict = identity?.mediaType === 'tv' && (numbers.season !== null && numbers.season !== identity.season || numbers.episode !== null && numbers.episode !== identity.episode);
      const year = tmdbSourceYear(session.metadata?.year || session.request?.metadataHint?.year, session.title, [session.episodeName]);
      const candidateYear = tmdbSourceYear(null, candidate.name) || String(candidate.name).match(/[\s._-]((?:19|20)\d{2})(?=$|[\s._-])/u)?.[1];
      const yearScore = year && candidateYear ? year === candidateYear ? 80 : -800 : 0;
      items.push({ id, candidateKey, provider: result.provider, name: String(candidate.name).slice(0, 500), language: String(candidate.language || ''),
        format: String(candidate.format || 'srt'), conflict: !!conflict, ...(candidate.externalUrl ? { externalUrl: candidate.externalUrl } : {}), score: (Number(candidate.score) || 0) + yearScore + (conflict ? -1000 : 0) });
    }
    return { searchId: job.id, sessionId, items: items.sort((a, b) => b.score - a.score),
      providers: results.map(({ provider, state, code }) => ({ provider, state, count: items.filter(item => item.provider === provider).length, ...(code ? { code } : {}) })),
      warnings: results.filter(item => item.warning).map(({ provider, warning, code }) => ({ provider, message: warning, code })),
      errors: results.filter((item) => item.error).map(({ provider, error }) => ({ provider, message: error })) };
  }
  async files({ sessionId, mediaVersion, searchId, candidateId }, signal) {
    this.session({ sessionId, mediaVersion });
    const job = this.job;
    if (!job || job.id !== searchId) throw new AppError('SUBTITLE_STALE', '字幕搜索已过期');
    this.check(job);
    const item = job.candidates.get(candidateId);
    if (!item) throw new AppError('SUBTITLE_MISSING', '字幕候选不存在');
    if (item.provider !== 'assrt') return { files: [] };
    const combined = signal ? AbortSignal.any([signal, job.controller.signal]) : job.controller.signal;
    if (!item.fileChoices) {
      const downloads = await this.assrtDownloads(item, combined, 20000);
      combined.throwIfAborted(); this.check(job);
      item.fileChoices = downloads.map(download => ({ ...download, id: randomUUID() }));
    }
    return { files: item.fileChoices.map(({ id, name, format }) => ({ id, name, format: format || ext(name) })) };
  }
  async download({ sessionId, mediaVersion, searchId, candidateId, fileId }, signal) {
    this.session({ sessionId, mediaVersion });
    const job = this.job;
    if (!job || job.id !== searchId || job.session.id !== sessionId) throw new AppError('SUBTITLE_STALE', '字幕搜索已过期');
    this.check(job);
    const item = job.candidates.get(candidateId);
    if (!item) throw new AppError('SUBTITLE_MISSING', '字幕候选不存在');
    if (item.externalUrl) throw new AppError('SUBTITLE_BROWSER_REQUIRED', '请在字幕网站下载，然后打开本地字幕文件');
    const selectedChoice = fileId === undefined ? null : item.fileChoices?.find(file => file.id === fileId);
    if (fileId !== undefined && !selectedChoice) throw new AppError('SUBTITLE_STALE', '字幕文件列表已过期，请重新选择');
    const cached = (await this.list({ sessionId, mediaVersion })).files.filter(file => file.candidateKey === item.candidateKey
      && (!selectedChoice || file.name === selectedChoice.name));
    this.check(job);
    if (cached.length) return { searchId, sessionId, files: cached };
    const combined = signal ? AbortSignal.any([signal, job.controller.signal]) : job.controller.signal;
    // Keep all files and any retry inside the player's 150-second RPC window.
    const deadline = item.provider === 'assrt' ? performance.now() + 120000 : Infinity;
    const requestTimeout = () => {
      const remaining = Math.ceil(Math.min(20000, deadline - performance.now()));
      if (remaining <= 0) throw new AppError('REQUEST_ABORTED', '字幕下载超时，请稍后重试');
      return remaining;
    };
    const downloads = selectedChoice ? [selectedChoice]
      : item.provider === 'subtitlecat' ? await subtitleCatDownload(item.pageUrl, (await this.settings.private()).subtitles.language, combined)
      : item.provider === 'subhd' ? await subHDDownload(item.pageUrl, combined)
      : item.provider === 'assrt' ? await this.assrtDownloads(item, combined, requestTimeout())
      : [{ url: item.url, name: item.name, format: item.format }];
    const headers = { ...browserHeaders, Referer: item.provider === 'xunlei' ? 'https://sl-m-ssl.xunlei.com/'
      : item.provider === 'assrt' ? 'https://assrt.net/' : ['subtitlecat', 'subhd'].includes(item.provider) ? item.pageUrl : 'https://www.shooter.cn/' };
    const read = (download) => {
      if (!download) throw new AppError('SUBTITLE_MISSING', '字幕文件已改变，请重新搜索');
      if (!/^https?:\/\//i.test(download.url || '')) throw new AppError('SUBTITLE_URL', '字幕地址无效');
      return fetchBuffer(download.url, { maxBytes: LIMIT, timeoutMs: requestTimeout(), signal: combined, label: '字幕', headers });
    };
    const files = [];
    let total = 0, refreshed;
    for (const download of downloads) {
      let selected = refreshed ? refreshed.find(file => file.name === download.name) : download, bytes;
      try { bytes = await read(selected); }
      catch (error) {
        this.check(job);
        if (error.httpStatus === 493) throw new AppError('SUBTITLE_PROVIDER', '字幕文件服务器拒绝此下载（HTTP 493），请选其他字幕来源或文件');
        if (error.code === 'HTTP_ERROR' && error.httpStatus && ![403, 410, 429].includes(error.httpStatus) && error.httpStatus < 500) throw error;
        if (item.provider !== 'assrt' || combined.aborted || !retryableDownloadErrors.has(error.code)) throw error;
        // Assrt signs expiring URLs. Refresh once per group and retry only this
        // file, keeping completed files and using fresh URLs for the rest.
        refreshed ||= await this.assrtDownloads(item, combined, requestTimeout());
        this.check(job);
        selected = refreshed.find(file => file.name === download.name);
        bytes = await read(selected);
      }
      this.check(job);
      for (const file of subtitleFiles(bytes, selected.name, selected.format)) {
        total += file.bytes.length;
        if (total > LIMIT) throw new AppError('SUBTITLE_LIMIT', '字幕文件合计超过 8 MiB');
        files.push(file);
      }
    }
    requestTimeout();
    const results = [], episode = episodePreferenceKey(job.session.request || {});
    for (const file of files) {
      const content = file.bytes;
      if (content.length < 4 || /^\s*<(?:!doctype|html)/i.test(content.toString('utf8').slice(0, 200))) throw new AppError('SUBTITLE_FORMAT', '下载内容不是字幕');
      const id = randomUUID(), filename = episode + '-' + createHash('sha256').update(content).digest('hex') + '.' + ext(file.name);
      const location = path.join(this.directory, filename);
      await atomicWrite(location, content); this.check(job);
      const asset = { id, episode, file: filename, name: file.name, candidateKey: item.candidateKey, provider: item.provider };
      await this.downloads.update(data => { this.check(job); data.assets[id] = asset; });
      this.check(job);
      results.push({ id, name: file.name, candidateKey: item.candidateKey, provider: item.provider });
    }
    return { searchId, sessionId, files: results };
  }
  async asset(params) {
    const session = this.session(params);
    const asset = (await this.downloads.read()).assets[params.assetId];
    if (!asset || asset.episode !== episodePreferenceKey(session.request || {})) throw new AppError('SUBTITLE_MISSING', '请重新下载字幕');
    this.session(params);
    return { ...asset, path: this.location(asset) };
  }
  async remove(params) {
    const asset = await this.asset(params);
    await this.downloads.update(async data => {
      this.session(params);
      // Legacy caches may be shared by multiple remembered episodes.
      if (!Object.values(data.assets).some(other => other.id !== asset.id && other.file === asset.file))
        await fs.rm(this.location(asset), { force: true });
      delete data.assets[asset.id];
    });
    return { ok: true };
  }
}
