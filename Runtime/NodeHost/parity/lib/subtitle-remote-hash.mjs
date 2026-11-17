import { createHash } from 'node:crypto';
import { fetchResponse } from './http.mjs';
import { AppError } from './errors.mjs';
import { scopedMediaHeaders } from './media-cache.mjs';

const BLOCK_BYTES = 4096;
// Some subscription proxies expand a request to their fixed cache block. Only
// consume a small, fully validated superset, never a whole movie response.
const MAX_RANGE_BYTES = 64 * 1024;
const rangeError = message => new AppError('SUBTITLE_RANGE', message);
const segmentedError = () => new AppError('SUBTITLE_MEDIA', '当前视频使用分片播放，射手需要完整视频文件的指纹；可选择其他字幕来源');

export async function remoteShooterHash(address, headers = {}, signal) {
  const group = new AbortController(), combined = AbortSignal.any([group.signal, AbortSignal.timeout(25000), ...(signal ? [signal] : [])]);
  const range = async (start, end, previous) => {
    // Resolve the signed media location once. Re-entering a source redirect for
    // every block can mint different CDN URLs for the same file.
    let url = new URL(previous?.url || address), requestHeaders = new Headers(previous?.headers || headers);
    requestHeaders.set('Range', `bytes=${start}-${end}`);
    requestHeaders.set('Accept-Encoding', 'identity');
    requestHeaders.delete('If-Range');
    if (previous?.validator) requestHeaders.set('If-Range', previous.validator);
    for (let hop = 0; hop < 6; hop++) {
      const { response, release, url: resolvedUrl, headers: sentHeaders } = await fetchResponse(url.href,
        { headers: requestHeaders, signal: combined, timeoutMs: 10000, followRedirect: false, decompress: false });
      try {
        url = new URL(resolvedUrl);
        if ([301, 302, 303, 307, 308].includes(response.status)) {
          const location = response.headers.get('location'); if (!location) throw new Error();
          const next = new URL(location, url);
          if (!['http:', 'https:'].includes(next.protocol) || next.username || next.password || (url.protocol === 'https:' && next.protocol !== 'https:')) throw new Error();
          requestHeaders = new Headers(scopedMediaHeaders(sentHeaders, url, next));
          requestHeaders.set('Range', `bytes=${start}-${end}`);
          requestHeaders.set('Accept-Encoding', 'identity');
          if (previous?.validator) requestHeaders.set('If-Range', previous.validator);
          next.hash = '';
          url = next; continue;
        }
        const type = response.headers.get('content-type') || '';
        if (/mpegurl|dash\+xml/i.test(type)) throw segmentedError();
        if (/(?:text\/html|application\/(?:json|[^;\s]+\+json|xml))/i.test(type))
          throw new AppError('SUBTITLE_MEDIA', '当前线路返回了网页或接口数据，射手需要视频文件；请刷新线路或选择其他字幕来源');
        if (response.status === 200)
          throw rangeError('当前线路忽略了 Range 分段请求，射手无法读取视频指纹；可选择其他字幕来源');
        if ([401, 403].includes(response.status))
          throw rangeError(`当前线路拒绝字幕指纹读取（HTTP ${response.status}），请刷新播放线路或选择其他字幕来源`);
        const match = /^bytes\s+(\d+)-(\d+)\/(\d+)$/i.exec(response.headers.get('content-range') || '');
        const [rangeStart, rangeEnd, total] = match ? match.slice(1).map(Number) : [];
        const encoding = response.headers.get('content-encoding');
        const etag = response.headers.get('etag');
        const strongETag = etag && /^"[^"]*"$/.test(etag);
        const modified = response.headers.get('last-modified');
        const validatorHeader = strongETag ? 'etag' : modified && Number.isFinite(Date.parse(modified)) ? 'last-modified' : null;
        const validator = validatorHeader ? response.headers.get(validatorHeader) : null;
        const expectedLength = rangeEnd - rangeStart + 1, declaredLength = response.headers.get('content-length');
        if (response.status !== 206 || !match || ![rangeStart, rangeEnd, total].every(Number.isSafeInteger)
          || rangeStart < 0 || rangeEnd < rangeStart || rangeEnd >= total || total <= start
          || rangeStart > start || rangeEnd < Math.min(end, total - 1) || expectedLength > MAX_RANGE_BYTES
          || (declaredLength !== null && (!/^\d+$/.test(declaredLength) || Number(declaredLength) !== expectedLength))
          || (encoding && encoding.toLowerCase() !== 'identity'))
          throw rangeError('当前线路返回的分段范围或字节数无效，射手无法读取视频指纹；可选择其他字幕来源');
        if (previous && (previous.total !== total || previous.url !== url.href || previous.validator !== validator || previous.validatorHeader !== validatorHeader))
          throw rangeError('视频地址或文件版本在读取中发生变化，射手无法安全匹配；请刷新线路后重试');
        const chunks = []; let length = 0;
        for await (const chunk of response.body) {
          length += chunk.length;
          if (length > expectedLength || length > MAX_RANGE_BYTES) throw rangeError('视频分段返回了超出声明的字节，射手匹配已停止');
          chunks.push(chunk);
        }
        if (length !== expectedLength) throw rangeError('视频分段已截断，射手无法读取完整指纹；请稍后重试');
        const bytes = Buffer.concat(chunks).subarray(start - rangeStart, Math.min(end, total - 1) - rangeStart + 1);
        if (start === 0) {
          const opening = bytes.subarray(0, 1024).toString('utf8').replace(/^\uFEFF/, '');
          if (/^\s*(?:#EXTM3U|(?:<\?xml[^>]*>\s*)?<MPD\b)/i.test(opening)) throw segmentedError();
          if (/^\s*(?:<!doctype\s+html|<(?:html|head|body)\b|\{\s*"(?:error|message|code|status)"\s*:)/i.test(opening))
            throw new AppError('SUBTITLE_MEDIA', '当前线路返回了网页或接口数据，射手需要视频文件；请刷新线路或选择其他字幕来源');
        }
        return { bytes, total, validator, validatorHeader, url: url.href, headers: sentHeaders };
      } finally { await response.body?.cancel().catch(() => {}); release(); }
    }
    throw new AppError('SUBTITLE_RANGE', '射手视频分段读取失败');
  };
  try {
    const first = await range(0, BLOCK_BYTES - 1);
    if (first.total < 12288) return '';
    // The selected subscription URL may already proxy parallel requests, or
    // may be a signed CDN line that forbids them. Keep fingerprint reads serial.
    const parts = [];
    for (const position of [4096, Math.floor(first.total / 3) * 2, Math.floor(first.total / 3), first.total - 8192])
      parts.push(createHash('md5').update((await range(position, position + BLOCK_BYTES - 1, first)).bytes).digest('hex'));
    return parts.join(';');
  } catch (error) {
    if (error instanceof AppError) throw error;
    throw new AppError('SUBTITLE_RANGE', '射手视频分段读取失败，请尝试其他字幕来源');
  } finally { group.abort(); }
}
