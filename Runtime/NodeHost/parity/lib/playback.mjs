import { createHash, randomUUID } from 'node:crypto';
import { AppError } from './errors.mjs';
import { cardNavigation, posterAddress } from './catalog.mjs';
import { lyricText } from './lyrics.mjs';
import { splitProxyTracks } from './media-streams.mjs';
import { originalHlsMedia } from './source-media.mjs';
import { normalizeLiveDanmaku } from './live-danmaku-config.mjs';

const string = (value) => (value == null ? '' : String(value));

function pathFormat(value) {
  let text = string(value);
  // Inspect a copy only. Decoding or changing the actual URL breaks signatures.
  try { if (/^[a-z][a-z\d+.-]*:\/\//i.test(text)) text = new URL(text).pathname; } catch {}
  try { text = decodeURIComponent(text); } catch {}
  // A source filename can contain codec labels such as ".AAC 2.0.mkv".
  // Prefer the last container suffix, without changing its signed transport URL.
  const matches = [...text.matchAll(/\.(iso|bdmv|mpls|m2ts|mp4|mkv|mov|ts|m3u8|mpd|mp3|m4a|aac|flac|wav|ogg|opus|wma|aiff|ape)(?=$|[\s?#\[\]()])/gi)];
  return matches.at(-1)?.[1].toLowerCase() || '';
}

function declaredFormat(value) {
  const text = string(value).toLowerCase().split(';', 1)[0].trim();
  if (/^(iso|bdmv|mpls|m2ts|mp4|mkv|mov|ts|m3u8|mpd|mp3|m4a|aac|flac|wav|ogg|opus|wma|aiff|ape)$/.test(text)) return text;
  return ({ 'application/x-iso9660-image': 'iso', 'application/x-iso-image': 'iso',
    'video/mp4': 'mp4', 'video/x-matroska': 'mkv', 'application/vnd.apple.mpegurl': 'm3u8',
    'application/x-mpegurl': 'm3u8', 'application/dash+xml': 'mpd', 'audio/mpeg': 'mp3',
    'audio/mp4': 'm4a', 'audio/aac': 'aac', 'audio/flac': 'flac', 'audio/wav': 'wav', 'audio/ogg': 'ogg' })[text] || '';
}

function mediaFormat(request, episodeName) {
  function nestedFormat(value, depth = 0) {
    if (depth > 4) return '';
    if (Array.isArray(value)) return value.slice(0, 32).map((item) => nestedFormat(item, depth + 1)).find(Boolean) || '';
    if (value && typeof value === 'object')
      return ['fileName', 'filename', 'file_name', 'name', 'path', 'url', 'file', 'n', 'p'].map((key) => nestedFormat(value[key], depth + 1)).find(Boolean) || '';
    return pathFormat(value);
  }
  // The opaque file identity retains its filename extension even when the UI
  // label drops it and ends in codec badges such as "AAC 2.0 [6.07GB]".
  for (const value of [request?.direct, request?.id, episodeName]) {
    const encoded = string(value).match(/^![^!]+!(.+)$/)
      || string(value).match(/^(?:webdav|play)@@@(.+)$/);
    if (!encoded) {
      const format = pathFormat(value);
      if (format) return format;
    } else if (encoded[1].length <= 65536) {
      try {
        const format = nestedFormat(JSON.parse(Buffer.from(encoded[1], 'base64url').toString('utf8')));
        if (format) return format;
      } catch {}
    }
  }
  return '';
}

export function normalizeHeaders(value) {
  if (typeof value === 'string') {
    try {
      value = JSON.parse(value);
    } catch {
      value = {};
    }
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
  return Object.fromEntries(
    Object.entries(value)
      .filter(
        ([key, item]) =>
          /^[!#$%&'*+.^_`|~\da-z-]+$/i.test(key) &&
          !/[\r\n]/.test(string(item)) &&
          !['host', 'connection', 'content-length', 'transfer-encoding'].includes(
            key.toLowerCase(),
          ),
      )
      .map(([key, item]) => [key, string(item)]),
  );
}

export function normalizeDetail(value) {
  const vod = Array.isArray(value?.list) ? value.list[0] : value;
  if (!vod || typeof vod !== 'object') throw new AppError('DETAIL_EMPTY', '来源未返回影片详情');
  const names = string(vod.vod_play_from).split('$$$');
  const lines = string(vod.vod_play_url)
    .split('$$$')
    .map((line, index) => ({
      name: names[index] || `线路 ${index + 1}`,
      episodes: line
        .split('#')
        .filter(Boolean)
        .map((episode, number) => {
          const split = episode.indexOf('$');
          return {
            name: split < 0 ? `第 ${number + 1} 集` : episode.slice(0, split),
            id: split < 0 ? episode : episode.slice(split + 1),
          };
        }),
    }))
    .filter((line) => line.episodes.length);
  return { ...vod, lines };
}

export function normalizePlayResult(
  value,
  { baseUrl, title = '', episodeName = '', request, position = 0 } = {},
) {
  let result = value;
  for (let attempt = 0; attempt < 3 && typeof result === 'string'; attempt++) {
    try {
      result = JSON.parse(result);
    } catch {
      result = { url: result };
    }
  }
  for (let depth = 0; depth < 3; depth++) {
    if (Array.isArray(result)) result = result[0];
    let nested = result?.data ?? result?.result ?? result?.play;
    if (typeof nested === 'string') {
      try {
        nested = JSON.parse(nested);
      } catch {}
    }
    if (!nested || typeof nested !== 'object') break;
    if (Array.isArray(nested)) {
      const payload = nested[0];
      const qualityArray =
        nested.length > 0 &&
        nested.every(
          (item) =>
            item &&
            typeof item === 'object' &&
            ['url', 'urls', 'play_url', 'playUrl', 'link', 'src', 'm3u8'].some(
              (key) => item[key] !== undefined,
            ),
        );
      result = qualityArray
        ? { ...result, url: result.url ?? nested }
        : {
            ...result,
            url: result.url ?? (payload && typeof payload === 'object' ? undefined : nested),
            ...(payload && typeof payload === 'object' ? payload : {}),
          };
    } else result = { ...result, ...nested };
  }
  if (!result || typeof result !== 'object') throw new AppError('PLAY_EMPTY', '来源未返回播放信息');
  const header = normalizeHeaders(result.header || result.headers);
  const format = declaredFormat(result.format || result.extra?.format) || mediaFormat(request, episodeName);
  const resolve = (value) => {
    const url = string(value)
      .trim()
      .replace(/js2p:\/\/_WEB_/gi, baseUrl || '');
    if (!url) return '';
    if (baseUrl && (/^\/{2}/.test(url) || !/^[a-z][a-z\d+.-]*:/i.test(url)))
      return new URL(url, baseUrl).toString();
    return url;
  };
  // Keep signed/proxy URLs byte-for-byte intact; the disc reader uses format
  // metadata to open the actual filesystem inside an ISO.
  const mediaUrl = (value) => {
    const prefix = Number(result.parse) === 1 && typeof result.playUrl === 'string' && value !== result.playUrl
      ? result.playUrl.trim() : '';
    return resolve(prefix ? prefix + string(value).trim() : value);
  };
  const qualities = [];
  const raw = [
    result.url,
    result.urls,
    result.play_url,
    result.playUrl,
    result.link,
    result.src,
    result.m3u8,
  ].find(
    (candidate) =>
      candidate !== undefined &&
      candidate !== null &&
      candidate !== '' &&
      (!Array.isArray(candidate) || candidate.length > 0),
  );
  if (typeof raw === 'string')
    qualities.push({ name: '默认', url: mediaUrl(raw), headers: header, format });
  else if (Array.isArray(raw)) {
    if (raw.every((item) => typeof item === 'string')) {
      if (raw.length === 1)
        qualities.push({ name: '默认', url: mediaUrl(raw[0]), headers: header, format });
      else
        for (let i = 0; i + 1 < raw.length; i += 2)
          qualities.push({
            name: string(raw[i]) || `线路 ${i / 2 + 1}`,
            url: mediaUrl(raw[i + 1]),
            headers: header,
            format,
          });
    } else
      for (const item of raw) {
        if (item && typeof item === 'object')
          qualities.push({
            name: string(item.name || item.label || '默认'),
            url: mediaUrl(item.url || item.link || item.src || item.m3u8),
            headers: { ...header, ...normalizeHeaders(item.header || item.headers) },
            format: declaredFormat(item.format) || format,
          });
      }
  } else if (raw && typeof raw === 'object') {
    const objectUrl = raw.url || raw.link || raw.src || raw.m3u8;
    if (typeof objectUrl === 'string')
      qualities.push({
        name: string(raw.name || raw.label || '默认'),
        url: mediaUrl(objectUrl),
        headers: { ...header, ...normalizeHeaders(raw.header || raw.headers) },
        format: declaredFormat(raw.format) || pathFormat(objectUrl) || format,
      });
    else
      for (const [name, url] of Object.entries(raw))
        if (typeof url === 'string')
          qualities.push({ name, url: mediaUrl(url), headers: header, format });
  }
  const available = qualities
    .filter((q) => q.url)
    .map((quality) => {
      if (Number(result.parse) === 1) {
        return { ...quality, format: '' };
      }
      const original = originalHlsMedia(quality.url, baseUrl);
      if (original) quality = { ...quality, url: original, fallbackUrl: quality.url, format: 'm3u8' };
      const streams = splitProxyTracks(quality.url, baseUrl);
      return streams
        ? { ...quality, url: streams.videoUrl, audioUrl: streams.audioUrl, format: 'mp4' }
        : { ...quality, format: pathFormat(quality.url) || quality.format };
    });
  if (!available.length)
    throw new AppError(
      'PLAY_EMPTY',
      string(result.message || result.error || '没有可播放地址，请尝试其他线路'),
    );
  const extra = result.extra && typeof result.extra === 'object' ? result.extra : {};
  const danmakuInput = extra.danmaku || result.danmaku || '';
  const liveDanmaku = normalizeLiveDanmaku(extra.liveDanmaku || result.liveDanmaku
    || (/^wss?:\/\//i.test(danmakuInput) ? danmakuInput : undefined), baseUrl);
  const danmaku = typeof danmakuInput === 'string' && !/^wss?:\/\//i.test(danmakuInput) ? resolve(danmakuInput) : '';
  const posterInput =
    result.poster ||
    result.pic ||
    result.cover ||
    extra.poster ||
    extra.pic ||
    request?.poster ||
    '';
  const poster = posterAddress(posterInput, baseUrl);
  const metadataHeaders = Object.fromEntries(
    Object.entries(header).filter(([key]) =>
      ['user-agent', 'referer', 'accept-language'].includes(key.toLowerCase()),
    ),
  );
  const posterHeaders = {
    ...metadataHeaders,
    ...normalizeHeaders(
      result.posterHeaders || extra.posterHeaders || posterInput?.headers || posterInput?.header,
    ),
  };
  const lyricsHeaders = {
    ...metadataHeaders,
    ...normalizeHeaders(result.lyricsHeaders || extra.lyricsHeaders),
  };
  const lyricsValue = lyricText(
    result.lrc ||
      result.lyric ||
      result.lyrics ||
      extra.lrc ||
      extra.lyric ||
      extra.lyrics ||
      result.lrc_url ||
      result.lyrics_url ||
      extra.lrc_url ||
      '',
  );
  const remoteLyrics =
    !/[\r\n]/.test(lyricsValue) &&
    (/^(?:https?:\/\/|js2p:\/\/_WEB_|\/|\.\.?\/)/i.test(lyricsValue) ||
      /^[^\s\[\]{}]+\.(?:lrc|txt)(?:[?#].*)?$/i.test(lyricsValue));
  const lyricsUrl = remoteLyrics ? resolve(lyricsValue) : '';
  const lyrics = remoteLyrics ? '' : lyricsValue;
  const subtitleInputs = [
    ...(Array.isArray(result.subs) ? result.subs : []),
    ...(Array.isArray(extra.subs) ? extra.subs : []),
  ];
  for (const entry of [
    result.subt,
    result.subtitle,
    extra.subt,
    extra.subtitle,
    ...(Array.isArray(result.subs_urls) ? result.subs_urls : []),
  ])
    if (entry) subtitleInputs.push(entry);
  const seen = new Set();
  const subtitles = subtitleInputs
    .map((item) => (typeof item === 'string' ? { url: item, name: '外挂字幕' } : item))
    .filter((item) => item?.url)
    .map((item) => ({
      name: string(item.name || item.title || '外挂字幕'),
      url: resolve(item.url),
      format: string(item.format || ''),
    }))
    .filter((item) => {
      if (
        item.url === danmaku ||
        /(?:danmu|danmaku|comment\.bilibili)/i.test(item.url) ||
        seen.has(item.url)
      )
        return false;
      seen.add(item.url);
      return true;
    });
  const identity = request
    ? JSON.stringify([request.sourceId, request.siteKey, request.vodId, request.flag, request.id])
    : available[0].url;
  return {
    id: randomUUID(),
    historyId: createHash('sha256').update(identity).digest('hex').slice(0, 32),
    title,
    episodeName,
    request,
    qualities: available,
    mediaKind: available.length && available.every(quality =>
      /^(?:mp3|m4a|aac|flac|wav|ogg|opus|wma|aiff|ape)$/i.test(quality.format || '')) ? 'audio' : undefined,
    subtitles,
    danmaku,
    ...(liveDanmaku ? { liveDanmaku } : {}),
    ...(liveDanmaku || result.isLive === true || result.live === true || result.type === 'live' ? { isLive: true } : {}),
    ...(typeof extra.liveDanmakuError === 'string' ? { liveDanmakuError: extra.liveDanmakuError.slice(0, 300) } : {}),
    poster,
    posterHeaders,
    lyrics,
    lyricsUrl,
    lyricsHeaders,
    audioUrl: resolve(result.audio || extra.audio || extra.audio_url || ''),
    parse: Number(result.parse) === 1,
    position: Math.max(0, Number(position) || 0),
    duration: 0,
    discPlaylist: Number.isInteger(request?.discPlaylist) && request.discPlaylist >= 0 && request.discPlaylist <= 99999 ? request.discPlaylist : null,
  };
}

export function normalizeVod(item, site = {}) {
  return {
    id: string(item.vod_id ?? item.id),
    name: string(item.vod_name ?? item.name ?? '未命名'),
    poster: string(item.vod_pic ?? item.pic),
    remarks: string(item.vod_remarks ?? item.remarks),
    year: string(item.vod_year ?? item.year),
    type: string(item.type_name ?? item.type),
    ...cardNavigation(item, site),
  };
}
