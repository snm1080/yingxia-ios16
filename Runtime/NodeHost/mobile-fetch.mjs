import http from 'node:http';
import https from 'node:https';
import { Readable } from 'node:stream';
import { createGunzip, createBrotliDecompress } from 'node:zlib';
import { createHTTPInflate } from './mobile-deflate.mjs';

// nodejs-mobile disables WebAssembly. Keep the fetch-shaped transport independent of undici/llhttp's WASM.
export async function mobileFetch(input, options = {}, remaining = 5, retryReusedSocket = true) {
  const url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url);
  if (!['http:', 'https:'].includes(url.protocol)) throw new Error('Unsupported HTTP protocol');
  const headers = new Headers(options.headers || {});
  let body = options.body;
  if (typeof FormData !== 'undefined' && body instanceof FormData) {
    const request = new Request(url, { method: options.method || 'POST', headers, body });
    body = Buffer.from(await request.arrayBuffer());
    for (const [key, value] of request.headers) headers.set(key, value);
  } else if (typeof Blob !== 'undefined' && body instanceof Blob) { body = Buffer.from(await body.arrayBuffer()); }
  else if (body instanceof URLSearchParams) { body = body.toString(); headers.set('content-type', 'application/x-www-form-urlencoded;charset=UTF-8'); }
  if (body != null && (typeof body === 'string' || Buffer.isBuffer(body) || body instanceof Uint8Array)) headers.set('content-length', String(Buffer.byteLength(body)));
  options.signal?.throwIfAborted();
  return await new Promise((resolve, reject) => {
    const request = (url.protocol === 'https:' ? https : http).request(url, { method: options.method || 'GET', headers: Object.fromEntries(headers) });
    const abort = () => request.destroy(options.signal.reason instanceof Error ? options.signal.reason : new Error('Request cancelled'));
    const cleanup = () => options.signal?.removeEventListener('abort', abort);
    options.signal?.addEventListener('abort', abort, { once: true });
    let receivedHeaders = false;
    request.once('error', error => {
      cleanup();
      // A source can close its idle loopback connection just as the agent
      // reuses it. Retry only that pre-response GET/HEAD once; source writes,
      // cancelled requests and fresh-connection failures retain their errors.
      if (retryReusedSocket && request.reusedSocket && !receivedHeaders
        && error.code === 'ECONNRESET' && !options.signal?.aborted
        && ['GET', 'HEAD'].includes(request.method) && body == null) {
        resolve(mobileFetch(url, options, remaining, false)); return;
      }
      reject(error);
    });
    request.once('response', async incoming => {
      receivedHeaders = true;
      const status = incoming.statusCode || 0;
      if ([301, 302, 303, 307, 308].includes(status) && incoming.headers.location && options.redirect !== 'manual') {
        incoming.resume(); cleanup();
        if (options.redirect === 'error' || remaining <= 0) { reject(new Error('HTTP redirect rejected')); return; }
        const next = new URL(incoming.headers.location, url);
        if (next.origin !== url.origin) { headers.delete('authorization'); headers.delete('cookie'); }
        const toGET = status === 303 || ([301,302].includes(status) && options.method === 'POST');
        if (toGET) { headers.delete('content-length'); headers.delete('content-type'); }
        try { resolve(await mobileFetch(next, { ...options, headers, method: toGET ? 'GET' : options.method, body: toGET ? undefined : body }, remaining - 1)); }
        catch (error) { reject(error); }
        return;
      }
      let stream = incoming;
      const encoding = incoming.headers['content-encoding'];
      // Byte-range fingerprints need the original representation and encoding
      // headers; ordinary provider/API requests retain transparent decoding.
      if (options.decompress !== false) {
        if (encoding === 'gzip') stream = incoming.pipe(createGunzip());
        else if (encoding === 'deflate') stream = incoming.pipe(createHTTPInflate());
        else if (encoding === 'br') stream = incoming.pipe(createBrotliDecompress());
      }
      if (stream !== incoming) {
        incoming.on('error', error => stream.destroy(error));
        // Cancelling a decoded-byte limit must also stop the compressed socket.
        stream.once('close', () => incoming.destroy());
      }
      incoming.once('close', cleanup);
      const responseHeaders = new Headers();
      for (const [key, value] of Object.entries(incoming.headers)) {
        if (value !== undefined) responseHeaders.set(key, Array.isArray(value) ? value.join(', ') : value);
      }
      if (stream !== incoming) { responseHeaders.delete('content-length'); responseHeaders.delete('content-encoding'); }
      const response = new Response([101,204,205,304].includes(status) || options.method === 'HEAD' ? null : Readable.toWeb(stream), { status: Math.max(200, status), headers: responseHeaders });
      Object.defineProperty(response, 'url', { value: url.href });
      resolve(response);
    });
    if (body == null) request.end();
    else if (typeof body === 'string' || Buffer.isBuffer(body) || body instanceof Uint8Array) request.end(body);
    else { request.destroy(new Error('Unsupported HTTP body')); }
  });
}
