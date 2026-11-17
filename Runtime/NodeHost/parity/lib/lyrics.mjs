import { fetchBuffer } from './http.mjs';
import { AppError } from './errors.mjs';

export function lyricText(value, depth = 0) {
  if (depth > 5 || value == null) return '';
  if (typeof value === 'string') {
    const text = value.replace(/^\uFEFF/, '').trim();
    if (/^[{\[]/.test(text)) {
      try {
        return lyricText(JSON.parse(text), depth + 1);
      } catch {}
    }
    return text;
  }
  if (Array.isArray(value))
    return value
      .map((item) => lyricText(item, depth + 1))
      .filter(Boolean)
      .join('\n');
  if (typeof value === 'object') {
    for (const key of ['lyric', 'lyrics', 'lrc', 'text', 'content', 'data', 'result', 'url']) {
      const text = lyricText(value[key], depth + 1);
      if (text) return text;
    }
  }
  return '';
}

export async function fetchLyrics(url, { headers = {}, signal, normalizeUrl } = {}) {
  let contentType = '';
  const bytes = await fetchBuffer(url, {
    headers,
    signal,
    normalizeUrl,
    timeoutMs: 12000,
    maxBytes: 1024 * 1024,
    label: '歌词',
    onResponse: (response) => {
      contentType = response.headers.get('content-type') || '';
    },
  });
  signal?.throwIfAborted();
  const encoding =
    bytes[0] === 0xff && bytes[1] === 0xfe
      ? 'utf-16le'
      : bytes[0] === 0xfe && bytes[1] === 0xff
        ? 'utf-16be'
        : contentType.match(/charset\s*=\s*["']?([^\s;"']+)/i)?.[1] || 'utf-8';
  let text;
  try {
    text = new TextDecoder(encoding, { fatal: true }).decode(bytes);
  } catch {
    throw new AppError('LYRICS_ENCODING', '歌词编码暂不支持，请重试或更换来源。');
  }
  if (/<(?:!doctype\s+html|html|body)\b/i.test(text.slice(0, 512)))
    throw new AppError('LYRICS_RESPONSE', '歌词来源返回了网页，请稍后重试。');
  return lyricText(text);
}
