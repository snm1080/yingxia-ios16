import net from 'node:net';
import tls from 'node:tls';
import http from 'node:http';
import https from 'node:https';
import { once } from 'node:events';
import { Readable } from 'node:stream';
import { createGunzip, createInflate, createBrotliDecompress } from 'node:zlib';
import { AppError } from './errors.mjs';
import { proxyUrl } from './proxy-settings.mjs';

const hostOf = url => url.hostname.replace(/^\[|\]$/g, '');
const failure = () => new AppError('PROXY_NETWORK', '代理连接失败，请检查代理地址和网络');
const authFailure = () => new AppError('PROXY_AUTH', '代理认证失败，请检查账号和密码');

// Read only the handshake bytes; leave subsequent TLS/HTTP bytes on the socket.
function readSocket(socket, size, signal) {
  return new Promise((resolve, reject) => {
    const cleanup = () => {
      socket.removeListener('readable', read); socket.removeListener('error', fail);
      socket.removeListener('end', ended); socket.removeListener('close', ended);
      signal?.removeEventListener('abort', abort);
    };
    const fail = error => { cleanup(); reject(error); };
    const ended = () => fail(failure());
    const abort = () => fail(signal.reason);
    const read = () => {
      const chunk = socket.read(size);
      if (chunk !== null) { cleanup(); resolve(chunk); }
      else if (socket.destroyed || socket.readableEnded) ended();
    };
    socket.on('readable', read); socket.once('error', fail);
    socket.once('end', ended); socket.once('close', ended);
    signal?.addEventListener('abort', abort, { once: true });
    if (signal?.aborted) abort(); else read();
  });
}

async function socksTunnel(socket, target, proxy, signal) {
  const username = Buffer.from(proxy.username || ''), password = Buffer.from(proxy.password || '');
  if (username.length > 255 || password.length > 255) throw authFailure();
  socket.write(Buffer.from(username.length ? [5, 2, 0, 2] : [5, 1, 0]));
  const greeting = await readSocket(socket, 2, signal);
  if (greeting[0] !== 5 || ![0, 2].includes(greeting[1])) throw authFailure();
  if (greeting[1] === 2) {
    if (!username.length) throw authFailure();
    socket.write(Buffer.concat([Buffer.from([1, username.length]), username, Buffer.from([password.length]), password]));
    const result = await readSocket(socket, 2, signal);
    if (result[0] !== 1 || result[1] !== 0) throw authFailure();
  }
  // Domain form delegates DNS to the proxy, including locally unresolvable hosts.
  const host = Buffer.from(hostOf(target));
  if (!host.length || host.length > 255) throw failure();
  const port = Buffer.alloc(2); port.writeUInt16BE(Number(target.port || (target.protocol === 'https:' ? 443 : 80)));
  socket.write(Buffer.concat([Buffer.from([5, 1, 0, 3, host.length]), host, port]));
  const reply = await readSocket(socket, 4, signal);
  if (reply[0] !== 5 || reply[1] !== 0 || reply[2] !== 0) throw failure();
  const length = reply[3] === 1 ? 4 : reply[3] === 4 ? 16
    : reply[3] === 3 ? (await readSocket(socket, 1, signal))[0] : 0;
  if (!length) throw failure();
  await readSocket(socket, length + 2, signal);
}

async function httpTunnel(socket, target, proxy, signal) {
  const authority = `${target.hostname}:${target.port || (target.protocol === 'https:' ? 443 : 80)}`;
  const auth = proxy.username ? `Proxy-Authorization: Basic ${Buffer.from(`${proxy.username}:${proxy.password || ''}`).toString('base64')}\r\n` : '';
  socket.write(`CONNECT ${authority} HTTP/1.1\r\nHost: ${authority}\r\n${auth}\r\n`);
  let header = Buffer.alloc(0);
  while (true) {
    header = Buffer.concat([header, await readSocket(socket, undefined, signal)]);
    const end = header.indexOf('\r\n\r\n');
    if (end > 16384 || (end < 0 && header.length > 16384)) throw failure();
    if (end < 0) continue;
    const status = /^HTTP\/1\.[01] (\d{3})(?: |\r)/.exec(header.toString('latin1'))?.[1];
    if (status === '407') throw authFailure();
    if (status !== '200') throw failure();
    if (header.length > end + 4) socket.unshift(header.subarray(end + 4));
    return;
  }
}

// Scoped fetch-compatible GET transport. Callers own deadlines, redirect policy
// and body limits. Each request owns its tunnel, so edited credentials take effect
// immediately and no authenticated sockets survive a settings change.
export async function proxyFetch(raw, { proxy, signal, headers, method = 'GET', body } = {}) {
  const target = new URL(raw), endpoint = new URL(proxyUrl(proxy.url));
  if (!['http:', 'https:'].includes(target.protocol)) throw failure();
  signal?.throwIfAborted();
  let socket, agent;
  const abort = () => socket?.destroy(signal.reason);
  signal?.addEventListener('abort', abort, { once: true });
  try {
    const secure = endpoint.protocol === 'https:', host = hostOf(endpoint);
    const options = { host, port: Number(endpoint.port || (secure ? 443 : endpoint.protocol === 'socks5:' ? 1080 : 80)) };
    socket = secure ? tls.connect({ ...options, servername: net.isIP(host) ? undefined : host }) : net.connect(options);
    // Keep errors observed between individual handshake reads.
    socket.on('error', () => {});
    await once(socket, secure ? 'secureConnect' : 'connect', { signal });
    if (endpoint.protocol === 'socks5:') await socksTunnel(socket, target, proxy, signal);
    else await httpTunnel(socket, target, proxy, signal);
    if (target.protocol === 'https:') {
      const host = hostOf(target);
      socket = tls.connect({ socket, host, servername: net.isIP(host) ? undefined : host });
      socket.on('error', () => {});
      await once(socket, 'secureConnect', { signal });
    }
    const transport = target.protocol === 'https:' ? https : http;
    agent = new transport.Agent({ keepAlive: false });
    agent.createConnection = () => socket;
    const outgoing = new Headers(headers);
    outgoing.delete('proxy-authorization'); outgoing.set('accept-encoding', 'gzip, deflate, br');
    const response = await new Promise((resolve, reject) => {
      const request = transport.request(target, { agent, method, headers: Object.fromEntries(outgoing), signal }, resolve);
      request.once('error', reject); request.end(body);
    });
    const cleanup = () => { signal?.removeEventListener('abort', abort); agent.destroy(); };
    response.once('close', cleanup);
    const responseHeaders = new Headers();
    for (let i = 0; i < response.rawHeaders.length; i += 2) responseHeaders.append(response.rawHeaders[i], response.rawHeaders[i + 1]);
    const noBody = method === 'HEAD' || [204, 205, 304].includes(response.statusCode);
    if (noBody) response.resume();
    let stream = response;
    const decompress = { gzip: createGunzip, deflate: createInflate, br: createBrotliDecompress }[response.headers['content-encoding']];
    if (decompress && !noBody) {
      stream = decompress();
      response.on('error', error => stream.destroy(error));
      stream.once('close', () => response.destroy());
      response.pipe(stream);
      responseHeaders.delete('content-encoding'); responseHeaders.delete('content-length');
    }
    return new Response(noBody ? null : Readable.toWeb(stream), { status: response.statusCode, headers: responseHeaders });
  } catch (error) {
    signal?.removeEventListener('abort', abort); socket?.destroy(); agent?.destroy();
    if (signal?.aborted) throw signal.reason;
    if (error instanceof AppError) throw error;
    throw failure();
  }
}
