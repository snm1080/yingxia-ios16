import fs from 'node:fs/promises';
import { pruneDanmakuCache } from './danmaku-cache.mjs';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { AppError } from './errors.mjs';
import { fetchBuffer } from './http.mjs';
import { atomicWrite, readLimited } from './files.mjs';
import { danmakuEffect } from './danmaku-effects.mjs';
import { writeDanmakuIndex } from './danmaku-index.mjs';
import { withCacheFileLock } from './cache-file-lock.mjs';

function decodeXml(text) {
  const named = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" };
  return text.replace(/&(#x[\da-f]+|#\d+|amp|lt|gt|quot|apos);/gi, (all, entity) => {
    if (entity.startsWith('#')) {
      const point =
        entity[1].toLowerCase() === 'x'
          ? parseInt(entity.slice(2), 16)
          : parseInt(entity.slice(1), 10);
      return Number.isFinite(point) && point <= 0x10ffff && point >= 0
        ? String.fromCodePoint(point)
        : '';
    }
    return named[entity.toLowerCase()] || all;
  });
}

export function parseDanmaku(text) {
  if (/<(?:!doctype\s+html|html|body)\b/i.test(text.slice(0, 4096)))
    throw new AppError('DANMAKU_HTML', '弹幕地址返回了网页，请检查弹幕服务或登录状态');
  const comments = [];
  const add = (time, mode, color, message, metadata = {}) => {
    const t = Number(time),
      m = Number(mode) || 1,
      c = typeof color === 'string' && /^#[\da-f]{6}$/i.test(color) ? parseInt(color.slice(1), 16) : Number(color);
    const content = danmakuEffect(m, message, metadata);
    const special = m === 7 || m === 9;
    const value = Array.from(String(content.text ?? '').replace(special ? /[\u0000-\u0009\u000b-\u001f]/g : /[\r\n\u0000-\u001f]/g, ' '))
      .slice(0, special ? 4096 : 300)
      .join('');
    if (!Number.isFinite(t) || t < 0 || !value.trim()) return;
    if (comments.length >= 100_000)
      throw new AppError('DANMAKU_LIMIT', '弹幕超过 100,000 条，未加载；请使用分集弹幕文件');
    comments.push({
      time: t,
      mode: m,
      color: Number.isFinite(c) ? Math.max(0, Math.min(0xffffff, c)) : 0xffffff,
      text: value,
      ...(content.effect ? { effect: content.effect } : {}),
    });
  };
  if (text.trimStart().startsWith('<')) {
    for (const match of text.matchAll(
      /<d\b([^>]*)>([\s\S]*?)<\/d>/gi,
    )) {
      const attributes = Object.fromEntries([...match[1].matchAll(/([\w-]+)\s*=\s*(["'])([\s\S]*?)\2/g)]
        .map(item => [item[1], decodeXml(item[3])]));
      if (!attributes.p) continue;
      const parts = attributes.p.split(',');
      add(
        parts[0],
        parts[1],
        parts[3],
        decodeXml(match[2].replace(/^<!\[CDATA\[([\s\S]*)\]\]>$/, '$1')),
        { ...attributes, fontSize: parts[2] },
      );
    }
  } else {
    let value;
    try {
      value = JSON.parse(text);
    } catch {
      throw new AppError('DANMAKU_FORMAT', '弹幕不是有效的 XML 或 JSON');
    }
    let entries = Array.isArray(value)
      ? value
      : value.comments || value.danmaku || value.danmu || value.data;
    if (entries && !Array.isArray(entries)) entries = entries.comments || entries.list || entries.onTimeCommentList;
    if (!Array.isArray(entries)) throw new AppError('DANMAKU_FORMAT', '暂不支持此 JSON 弹幕结构');
    for (const item of entries) {
      if (Array.isArray(item))
        add(
          item[0],
          Number(item[1]) === 1 ? 5 : Number(item[1]) === 2 ? 4 : 1,
          typeof item[2] === 'string' ? parseInt(item[2].replace('#', ''), 16) : item[2],
          item[4],
          item[5],
        );
      else if (item && typeof item === 'object') {
        const parts = typeof item.p === 'string' ? item.p.split(',') : [];
        add(
          item.time ?? item.t ?? item.timepoint ?? (item.time_offset !== undefined ? Number(item.time_offset) / 1000 : parts[0]),
          item.mode ?? parts[1],
          item.color ?? parts[2],
          item.text ?? item.content ?? item.m,
          item,
        );
      }
    }
  }
  if (!comments.length) throw new AppError('DANMAKU_EMPTY', '没有找到可显示的弹幕');
  return comments.sort((a, b) => a.time - b.time);
}

export function decodeDanmaku(bytes, contentType = '') {
  let encoding;
  if (bytes[0] === 0xff && bytes[1] === 0xfe) encoding = 'utf-16le';
  else if (bytes[0] === 0xfe && bytes[1] === 0xff) encoding = 'utf-16be';
  else if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) encoding = 'utf-8';
  else if (bytes[0] === 0x3c && bytes[1] === 0) encoding = 'utf-16le';
  else if (bytes[0] === 0 && bytes[1] === 0x3c) encoding = 'utf-16be';
  else
    encoding =
      bytes
        .subarray(0, 512)
        .toString('ascii')
        .match(/<\?xml[^>]*encoding\s*=\s*["']([^"']+)/i)?.[1] ||
      contentType.match(/charset\s*=\s*["']?([^\s;"']+)/i)?.[1];
  try {
    return new TextDecoder(encoding || 'utf-8', { fatal: true }).decode(bytes);
  } catch {
    // Older XML services often send GBK without declaring it. Never guess an encoding for JSON.
    if (!encoding && bytes.subarray(0, 128).toString('ascii').trimStart().startsWith('<')) {
      try {
        return new TextDecoder('gb18030', { fatal: true }).decode(bytes);
      } catch {}
    }
    throw new AppError(
      'DANMAKU_ENCODING',
      '弹幕文件编码无效或不受支持，请使用 UTF-8、GBK 或 UTF-16 文件',
    );
  }
}

export async function cachedDanmaku(directory, cacheId) {
  if (typeof cacheId !== 'string' || !/^[a-f\d]{64}$/.test(cacheId)) return '';
  const file = path.join(directory, `${cacheId}.xml`);
  return withCacheFileLock(file, async () => {
    try {
      const bytes = await readLimited(file, 64 * 1024 ** 2);
      if (createHash('sha256').update(bytes).digest('hex') !== cacheId) return '';
      await fs.utimes(file, new Date(), new Date()).catch(() => {});
      return file;
    } catch { return ''; }
  });
}

// Read and verify under the same lock: a prune or replacement cannot change the
// bytes between verification and the mobile player's replay of a saved track.
export async function readCachedDanmaku(directory, cacheId) {
  if (typeof cacheId !== 'string' || !/^[a-f\d]{64}$/.test(cacheId)) return null;
  const file = path.join(directory, `${cacheId}.xml`);
  return withCacheFileLock(file, async () => {
    try {
      const bytes = await readLimited(file, 64 * 1024 ** 2);
      if (createHash('sha256').update(bytes).digest('hex') !== cacheId) return null;
      await fs.utimes(file, new Date(), new Date()).catch(() => {});
      return decodeDanmaku(bytes);
    } catch { return null; }
  });
}

export async function cacheDanmakuDocument(directory, text) {
  const bytes = Buffer.from('\uFEFF' + text);
  if (bytes.length > 64 * 1024 ** 2) return undefined;
  const cacheId = createHash('sha256').update(bytes).digest('hex');
  const file = path.join(directory, `${cacheId}.xml`);
  await fs.mkdir(directory, { recursive: true, mode: 0o700 });
  await withCacheFileLock(file, () => atomicWrite(file, bytes));
  await pruneDanmakuCache(directory, { keep: [cacheId] }).catch(() => {});
  return cacheId;
}

export async function prepareDanmaku(input, directory, sessionId, { signal, normalizeUrl, cacheDirectory } = {}) {
  if (!/^[a-f\d-]+$/.test(sessionId)) throw new AppError('INVALID_SESSION', '播放会话无效');
  let contentType = '';
  signal?.throwIfAborted();
  const bytes = /^https?:\/\//i.test(input)
    ? await fetchBuffer(input, {
        maxBytes: 32 * 1024 ** 2,
        label: '弹幕',
        timeoutMs: 45_000,
        signal,
        normalizeUrl,
        onResponse: (response) => {
          contentType = response.headers.get('content-type') || '';
        },
      })
    : await readLimited(input, (cacheDirectory && path.dirname(input) === cacheDirectory ? 64 : 32) * 1024 ** 2);
  signal?.throwIfAborted();
  const text = decodeDanmaku(bytes, contentType);
  const comments = parseDanmaku(text);
  await fs.mkdir(directory, { recursive: true, mode: 0o700 });
  const file = path.join(directory, `${sessionId}-${randomUUID()}.json`);
  try {
    const indexed = comments.length > 2000;
    if (indexed) await writeDanmakuIndex(file, comments, { signal });
    else await atomicWrite(file, JSON.stringify(comments));
    signal?.throwIfAborted();
    let cacheId;
    if (cacheDirectory) {
      // Preserve the original parsed document, including advanced-mode metadata.
      // A UTF-8 BOM overrides old XML charset declarations when replaying it.
      const cached = Buffer.from('\uFEFF' + text);
      cacheId = createHash('sha256').update(cached).digest('hex');
      const cacheFile = path.join(cacheDirectory, `${cacheId}.xml`);
      await withCacheFileLock(cacheFile, () => atomicWrite(cacheFile, cached));
      await pruneDanmakuCache(cacheDirectory, { keep: [cacheId] }).catch(() => {});
      signal?.throwIfAborted();
    }
    return { path: file, count: comments.length, indexed, ...(cacheId ? { cacheId } : {}) };
  } catch (error) {
    await fs.rm(file, { force: true });
    throw error;
  }
}
