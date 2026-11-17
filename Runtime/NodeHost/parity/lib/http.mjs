import fs from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { AppError } from './errors.mjs';
import { proxyFetch } from './proxy-http.mjs';

export function stripCredentials(raw) {
  const url = new URL(raw);
  let authorization;
  try {
    if (url.username || url.password)
      authorization = `Basic ${Buffer.from(`${decodeURIComponent(url.username)}:${decodeURIComponent(url.password)}`, 'utf8').toString('base64')}`;
  } catch {
    throw new AppError('INVALID_CREDENTIALS', '地址中的用户名或密码编码无效');
  }
  url.username = '';
  url.password = '';
  url.hash = '';
  return { url, authorization };
}

function canForwardCredentials(from, to) {
  return (
    from.origin === to.origin ||
    (from.protocol === 'http:' &&
      to.protocol === 'https:' &&
      from.hostname === to.hostname &&
      !from.port &&
      !to.port)
  );
}

export async function fetchResponse(
  raw,
  {
    authorization,
    headers = {},
    timeoutMs = 60_000,
    signal,
    allowInsecureRedirect = false,
    browserRedirects = false,
    followRedirect = true,
    proxy,
    normalizeUrl = (value) => value,
    ...options
  } = {},
) {
  let { url, authorization: embeddedAuth } = stripCredentials(normalizeUrl(raw));
  let auth = authorization || embeddedAuth || new Headers(headers).get('authorization');
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(new Error('请求超时')), timeoutMs);
  timer.unref?.();
  const combined = signal ? AbortSignal.any([signal, controller.signal]) : controller.signal;
  try {
    for (let hops = 0; hops <= 5; hops++) {
      if (!['http:', 'https:'].includes(url.protocol))
        throw new AppError('URL_PROTOCOL', '只支持 HTTP 或 HTTPS 地址');
      const requestHeaders = new Headers(headers);
      requestHeaders.delete('authorization');
      if (!requestHeaders.has('user-agent')) requestHeaders.set('user-agent', 'wincat/0.1');
      if (auth) requestHeaders.set('authorization', auth);
      let response;
      try {
        response = await (proxy ? proxyFetch : fetch)(url, {
          ...options,
          ...(proxy ? { proxy } : {}),
          headers: requestHeaders,
          redirect: 'manual',
          signal: combined,
        });
      } catch (error) {
        if (combined.aborted)
          throw new AppError('REQUEST_ABORTED', signal?.aborted ? '操作已取消' : '网络请求超时');
        if (error instanceof AppError) throw error;
        throw new AppError('NETWORK_ERROR', `无法连接 ${url.hostname}，请检查地址和网络`);
      }
      if (followRedirect && [301, 302, 303, 307, 308].includes(response.status)) {
        const location = response.headers.get('location');
        await response.body?.cancel();
        if (!location) throw new AppError('BAD_REDIRECT', '服务器返回了无效的重定向');
        const next = new URL(normalizeUrl(new URL(location, url).toString()));
        if (!allowInsecureRedirect && url.protocol === 'https:' && next.protocol === 'http:')
          throw new AppError('INSECURE_REDIRECT', '服务器把 HTTPS 重定向到了 HTTP');
        if (!canForwardCredentials(url, next)) auth = undefined;
        if (browserRedirects && (response.status === 303 && options.method !== 'HEAD'
          || [301, 302].includes(response.status) && options.method === 'POST')) {
          options = { ...options, method: 'GET', body: undefined };
          headers = Object.fromEntries(new Headers(headers));
          delete headers['content-type']; delete headers['content-length'];
        }
        next.username = '';
        next.password = '';
        next.hash = '';
        url = next;
        continue;
      }
      return { response, release: () => clearTimeout(timer), url: url.toString(),
        redirected: hops > 0, headers: Object.fromEntries(requestHeaders) };
    }
    throw new AppError('TOO_MANY_REDIRECTS', '服务器重定向次数过多');
  } catch (error) {
    clearTimeout(timer);
    throw error;
  }
}

export async function fetchBuffer(
  url,
  { maxBytes = 64 * 1024 * 1024, label = '文件', progress, onResponse, ...options } = {},
) {
  const { response, release } = await fetchResponse(url, options);
  try {
    if (!response.ok) {
      await response.body?.cancel();
      const error = new AppError(
        'HTTP_ERROR',
        `${label}读取失败（HTTP ${response.status}${response.status === 401 ? '，请检查用户名和密码' : ''}）`,
        502,
      );
      error.httpStatus = response.status;
      throw error;
    }
    const total = Number(response.headers.get('content-length')) || 0;
    onResponse?.(response);
    if (total > maxBytes) {
      await response.body?.cancel();
      throw new AppError('FILE_TOO_LARGE', `${label}超过大小限制`);
    }
    const chunks = [];
    let count = 0;
    for await (const chunk of response.body) {
      count += chunk.length;
      if (count > maxBytes) throw new AppError('FILE_TOO_LARGE', `${label}超过大小限制`);
      chunks.push(chunk);
      progress?.(count, total);
    }
    return Buffer.concat(chunks);
  } catch (error) {
    if (error instanceof AppError) throw error;
    throw new AppError('DOWNLOAD_INTERRUPTED', `${label}下载中断，请重试`);
  } finally {
    release();
  }
}

export async function downloadVerified(url, destination, expectedSha256, onProgress, signal) {
  if (!/^[a-f0-9]{64}$/i.test(expectedSha256))
    throw new AppError('NO_DIGEST', '发布文件缺少有效的 SHA-256 校验值');
  const { response, release } = await fetchResponse(url, { timeoutMs: 15 * 60_000, signal });
  const temporary = `${destination}.partial`;
  let handle;
  try {
    if (!response.ok)
      throw new AppError('DOWNLOAD_FAILED', `组件下载失败（HTTP ${response.status}）`);
    handle = await fs.open(temporary, 'w', 0o600);
    const hash = createHash('sha256');
    const total = Number(response.headers.get('content-length')) || 0;
    let downloaded = 0;
    for await (const chunk of response.body) {
      downloaded += chunk.length;
      if (downloaded > 2 * 1024 ** 3) throw new AppError('FILE_TOO_LARGE', '组件超过大小限制');
      hash.update(chunk);
      await handle.writeFile(chunk);
      onProgress?.({ downloaded, total });
    }
    await handle.close();
    handle = null;
    if (hash.digest('hex').toLowerCase() !== expectedSha256.toLowerCase())
      throw new AppError('HASH_MISMATCH', '组件 SHA-256 校验失败，请重新下载');
    await fs.rename(temporary, destination);
    return destination;
  } finally {
    release();
    await handle?.close();
    await fs.rm(temporary, { force: true });
  }
}
