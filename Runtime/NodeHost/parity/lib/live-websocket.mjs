import http from 'node:http';
import https from 'node:https';
import { createHash, randomBytes } from 'node:crypto';

const MAX_MESSAGE = 4 * 1024 * 1024;
const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

// Node's browser WebSocket cannot send the Origin/Cookie headers required by
// live platforms. Keep this transport small: no redirects or extensions, and
// validate lengths before buffering any untrusted frame or fragmented message.
export function connectLiveWebSocket(config, handlers, { timeoutMs = 10000, idleMs = 90000 } = {}) {
  let socket, idleTimer, stopped = false, ready = false;
  let buffer = Buffer.alloc(0), fragments = [], fragmentBytes = 0, fragmentOpcode = 0;
  const key = randomBytes(16).toString('base64');
  const url = new URL(config.url);
  url.protocol = url.protocol === 'wss:' ? 'https:' : 'http:';
  const request = (url.protocol === 'https:' ? https : http).request(url, {
    method: 'GET', agent: false,
    headers: { ...config.headers, Upgrade: 'websocket', Connection: 'Upgrade', 'Sec-WebSocket-Key': key, 'Sec-WebSocket-Version': '13' },
  });
  const timer = setTimeout(() => fail('实时弹幕连接超时'), timeoutMs);
  timer.unref?.();
  function close() {
    if (stopped) return;
    stopped = true; ready = false;
    clearTimeout(timer);
    clearTimeout(idleTimer);
    request.destroy(); socket?.destroy();
    buffer = Buffer.alloc(0); fragments = []; fragmentBytes = 0;
  }
  function fail(message) {
    if (stopped) return;
    close(); handlers.close(message);
  }
  function received() {
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => fail('实时弹幕连接无响应'), idleMs);
    idleTimer.unref?.();
  }
  function send(data, opcode = typeof data === 'string' ? 1 : 2) {
    if (!ready || stopped) return;
    const body = Buffer.isBuffer(data) ? data : Buffer.from(data);
    if (body.length > MAX_MESSAGE || socket.writableLength > MAX_MESSAGE) { fail('实时弹幕发送队列过大'); return; }
    const extended = body.length < 126 ? 0 : body.length <= 65535 ? 2 : 8;
    const frame = Buffer.alloc(2 + extended + 4 + body.length);
    frame[0] = 0x80 | opcode;
    frame[1] = 0x80 | (extended === 0 ? body.length : extended === 2 ? 126 : 127);
    if (extended === 2) frame.writeUInt16BE(body.length, 2);
    if (extended === 8) frame.writeBigUInt64BE(BigInt(body.length), 2);
    const mask = randomBytes(4); mask.copy(frame, 2 + extended);
    for (let i = 0; i < body.length; i++) frame[6 + extended + i] = body[i] ^ mask[i % 4];
    socket.write(frame);
  }
  function receive(chunk) {
    if (stopped) return;
    if (buffer.length + chunk.length > MAX_MESSAGE + 65536) { fail('实时弹幕数据过大'); return; }
    buffer = buffer.length ? Buffer.concat([buffer, chunk]) : chunk;
    while (!stopped && buffer.length >= 2) {
      const opcode = buffer[0] & 15, final = Boolean(buffer[0] & 128);
      let size = buffer[1] & 127, offset = 2;
      if ((buffer[0] & 112) || (buffer[1] & 128) || ![0, 1, 2, 8, 9, 10].includes(opcode)) { fail('实时弹幕帧格式无效'); return; }
      if (opcode >= 8 && (!final || size > 125)) { fail('实时弹幕控制帧无效'); return; }
      if (size === 126) {
        if (buffer.length < 4) return;
        size = buffer.readUInt16BE(2); offset = 4;
      } else if (size === 127) {
        if (buffer.length < 10) return;
        const length = buffer.readBigUInt64BE(2);
        if (length > BigInt(MAX_MESSAGE)) { fail('实时弹幕数据过大'); return; }
        size = Number(length); offset = 10;
      }
      if (size > MAX_MESSAGE || (opcode < 8 && fragmentBytes + size > MAX_MESSAGE)) { fail('实时弹幕数据过大'); return; }
      if (buffer.length < offset + size) return;
      const body = buffer.subarray(offset, offset + size);
      buffer = buffer.subarray(offset + size);
      received();
      if (opcode === 8) { fail('实时弹幕连接已关闭'); return; }
      if (opcode === 9) { send(body, 10); continue; }
      if (opcode === 10) continue;
      if ((opcode === 0 && !fragmentOpcode) || (opcode !== 0 && fragmentOpcode)) { fail('实时弹幕分片无效'); return; }
      if (!final || opcode === 0) {
        if (opcode !== 0) fragmentOpcode = opcode;
        fragments.push(Buffer.from(body)); fragmentBytes += size;
        if (fragments.length > 4096) { fail('实时弹幕分片过多'); return; }
        if (!final) continue;
        const message = Buffer.concat(fragments, fragmentBytes);
        fragments = []; fragmentBytes = 0; fragmentOpcode = 0;
        handlers.message(message);
      } else handlers.message(body);
    }
  }
  request.on('upgrade', (response, stream, head) => {
    socket = stream;
    if (stopped) { stream.destroy(); return; }
    const expected = createHash('sha1').update(key + GUID).digest('base64');
    if (response.statusCode !== 101 || response.headers['sec-websocket-accept'] !== expected
      || response.headers.upgrade?.toLowerCase() !== 'websocket'
      || !response.headers.connection?.toLowerCase().split(/\s*,\s*/).includes('upgrade')
      || response.headers['sec-websocket-extensions'] || response.headers['sec-websocket-protocol']) {
      fail('实时弹幕握手无效'); return;
    }
    clearTimeout(timer); ready = true;
    socket.on('data', receive);
    socket.on('error', () => fail('实时弹幕网络连接失败'));
    socket.on('close', () => fail('实时弹幕连接已断开'));
    received();
    handlers.open();
    if (head.length) receive(head);
  });
  request.on('response', response => { response.destroy(); fail(`实时弹幕服务返回 HTTP ${response.statusCode}`); });
  request.on('error', () => fail('实时弹幕网络连接失败'));
  request.end();
  return { send, close, ping: () => send(Buffer.alloc(0), 9) };
}
