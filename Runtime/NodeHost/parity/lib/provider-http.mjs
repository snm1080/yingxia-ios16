import { AppError } from './errors.mjs';
import { proxyFetch } from './proxy-http.mjs';

export function serviceUrl(value, label = '服务地址', { allowHttp = false } = {}) {
  let url;
  try { url = new URL(value); } catch { throw new AppError('SERVICE_URL', `${label}无效`); }
  const local = ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname);
  if ((url.protocol !== 'https:' && !((allowHttp || local) && url.protocol === 'http:')) || url.username || url.password)
    throw new AppError('SERVICE_URL', `${label}需要${allowHttp ? ' HTTP 或 HTTPS' : ' HTTPS（本机服务可使用 HTTP）'}，凭据请单独填写`);
  url.hash = '';
  return url.toString().replace(/\/$/, '');
}

// API redirects are deliberately rejected: API keys may live in custom headers or query strings.
export async function providerRequest(url, { signal, timeoutMs = 20000, maxBytes = 2 * 1024 ** 2,
  label = '服务', headers = {}, json, acceptHttpErrors = false, proxy, ...options } = {}) {
  const deadline = AbortSignal.timeout(timeoutMs);
  const combined = signal ? AbortSignal.any([signal, deadline]) : deadline;
  let response;
  try {
    response = await (proxy ? proxyFetch : fetch)(url, { ...options, ...(proxy ? { proxy } : {}), method: options.method || (json === undefined ? 'GET' : 'POST'),
      headers: { 'User-Agent': 'WinCat/0.2', ...headers, ...(json === undefined ? {} : { 'Content-Type': 'application/json' }) },
      body: json === undefined ? options.body : JSON.stringify(json), signal: combined, redirect: 'manual' });
    // Some providers return their documented JSON error codes with 4xx/5xx.
    // Opting into those bodies must never opt into API redirects.
    if (!response.ok && !(acceptHttpErrors && response.status >= 400)) {
      await response.body?.cancel();
      const error = new AppError('PROVIDER_HTTP', `${label}请求失败（HTTP ${response.status}）`);
      error.httpStatus = response.status;
      throw error;
    }
    if (Number(response.headers.get('content-length')) > maxBytes) {
      await response.body?.cancel();
      throw new AppError('PROVIDER_LIMIT', `${label}返回内容过大`);
    }
    const chunks = [];
    let length = 0;
    for await (const chunk of response.body) {
      length += chunk.length;
      if (length > maxBytes) throw new AppError('PROVIDER_LIMIT', `${label}返回内容过大`);
      chunks.push(chunk);
    }
    return Buffer.concat(chunks);
  } catch (error) {
    if (combined.aborted) throw new AppError('REQUEST_ABORTED', signal?.aborted ? '操作已取消' : `${label}请求超时`);
    if (error instanceof AppError) throw error;
    throw new AppError('PROVIDER_NETWORK', `${label}连接失败，请检查网络和服务配置`);
  }
}

export async function providerJson(url, options) {
  const bytes = await providerRequest(url, options);
  try { return JSON.parse(bytes.toString('utf8')); }
  catch { throw new AppError('PROVIDER_JSON', '服务返回了无效 JSON'); }
}
