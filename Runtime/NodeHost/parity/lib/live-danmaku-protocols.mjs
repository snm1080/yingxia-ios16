import { brotliDecompressSync, inflateSync } from 'node:zlib';
import { createDouyinProtocol } from './live-danmaku-douyin.mjs';

// Limits apply before allocation, including the total expanded bytes of nested packets.
const MAX_PACKET_BYTES = 2 * 1024 * 1024;
const MAX_DECODE_BYTES = 8 * 1024 * 1024;
const MAX_COMMENTS = 512;
const MAX_FIELDS = 32768;
const MAX_DEPTH = 16;

function emptyResult() { return { comments: [], replies: [] }; }
function inputBuffer(data) {
  if (typeof data === 'string') {
    if (Buffer.byteLength(data) > MAX_DECODE_BYTES) return null;
    return Buffer.from(data);
  }
  if (Buffer.isBuffer(data)) return data.length <= MAX_DECODE_BYTES ? data : null;
  if (data instanceof Uint8Array) return data.byteLength <= MAX_DECODE_BYTES ? Buffer.from(data.buffer, data.byteOffset, data.byteLength) : null;
  if (data instanceof ArrayBuffer) return data.byteLength <= MAX_DECODE_BYTES ? Buffer.from(data) : null;
  return null;
}
function numericId(value, name, { allowZero = false } = {}) {
  const id = String(value ?? '');
  if (!/^\d{1,19}$/.test(id) || (!allowZero && BigInt(id) === 0n) || BigInt(id) > 0x7fffffffffffffffn) {
    throw new Error(`Invalid live ${name} identifier`);
  }
  return id;
}
function colorValue(value) {
  if (typeof value === 'string' && /^#?[0-9a-f]{6}$/i.test(value)) return Number.parseInt(value.replace('#', ''), 16);
  const color = Number(value);
  return Number.isInteger(color) && color >= 0 && color <= 0xffffff ? color : 0xffffff;
}
function chat(text, color = 0xffffff, mode = 1) {
  if (typeof text !== 'string') return null;
  text = text.trim();
  if (!text || text.length > 4096) return null;
  mode = Number(mode);
  return { text, color: colorValue(color), mode: [1, 4, 5, 6].includes(mode) ? mode : 1 };
}
function appendChat(comments, text, color, mode) {
  if (comments.length >= MAX_COMMENTS) return;
  const comment = chat(text, color, mode);
  if (comment) comments.push(comment);
}

function bilibiliPacket(operation, body) {
  const bytes = Buffer.isBuffer(body) ? body : Buffer.from(body);
  const header = Buffer.alloc(16);
  header.writeUInt32BE(16 + bytes.length, 0);
  header.writeUInt16BE(16, 4);
  header.writeUInt16BE(1, 6);
  header.writeUInt32BE(operation, 8);
  header.writeUInt32BE(1, 12);
  return Buffer.concat([header, bytes]);
}

function createBilibiliProtocol(config) {
  const roomId = Number(numericId(config.roomId, 'room'));
  const uid = Number(numericId(config.uid ?? 0, 'user', { allowZero: true }));
  if (!Number.isSafeInteger(roomId) || !Number.isSafeInteger(uid)) throw new Error('Invalid live room or user identifier');
  let pending = Buffer.alloc(0);
  return {
    open() {
      pending = Buffer.alloc(0);
      const auth = { uid, roomid: roomId, protover: 3, platform: 'web', type: 2 };
      if (typeof config.token === 'string' && config.token) auth.key = config.token;
      if (typeof config.buvid === 'string' && config.buvid) auth.buvid = config.buvid;
      return [bilibiliPacket(7, JSON.stringify(auth))];
    },
    heartbeat() { return [bilibiliPacket(2, '[object Object]')]; },
    decode(data) {
      const result = emptyResult();
      const input = inputBuffer(data);
      if (!input || input.length + pending.length > MAX_DECODE_BYTES) { pending = Buffer.alloc(0); return result; }
      const bytes = pending.length ? Buffer.concat([pending, input]) : input;
      pending = Buffer.alloc(0);
      const budget = { bytes: MAX_DECODE_BYTES, packets: 4096 };
      const readPackets = (buffer, depth, retainPartial) => {
        if (depth > 4) return;
        let offset = 0;
        while (offset < buffer.length && budget.packets-- > 0) {
          const remaining = buffer.length - offset;
          if (remaining < 16) {
            if (retainPartial) pending = Buffer.from(buffer.subarray(offset));
            return;
          }
          const size = buffer.readUInt32BE(offset);
          const headerSize = buffer.readUInt16BE(offset + 4);
          const version = buffer.readUInt16BE(offset + 6);
          const operation = buffer.readUInt32BE(offset + 8);
          if (size < 16 || size > MAX_PACKET_BYTES || headerSize < 16 || headerSize > size) return;
          if (size > remaining) {
            if (retainPartial) pending = Buffer.from(buffer.subarray(offset));
            return;
          }
          const body = buffer.subarray(offset + headerSize, offset + size);
          offset += size;
          if (operation === 5 && (version === 2 || version === 3)) {
            if (budget.bytes <= 0) continue;
            let expanded;
            try {
              expanded = (version === 3 ? brotliDecompressSync : inflateSync)(body, { maxOutputLength: budget.bytes });
            } catch { continue; }
            budget.bytes -= expanded.length;
            readPackets(expanded, depth + 1, false);
            continue;
          }
          if ((operation !== 5 && operation !== 8) || (version !== 0 && version !== 1)) continue;
          let payload;
          try { payload = JSON.parse(body.toString('utf8')); } catch { continue; }
          if (operation === 8) {
            if (typeof payload?.code === 'number' && payload.code !== 0) throw new Error(`Bilibili live auth failed (${payload.code})`);
            continue;
          }
          if (typeof payload?.cmd !== 'string' || !['DANMU_MSG', 'DANMU_MSG_MIRROR'].includes(payload.cmd.split(':')[0])) continue;
          const info = payload.info;
          if (!Array.isArray(info) || !Array.isArray(info[0])) continue;
          if (info[0][9] != null && Number(info[0][9]) !== 0) continue;
          appendChat(result.comments, info[1], info[0][3], info[0][1]);
        }
      };
      readPackets(bytes, 0, true);
      return result;
    },
  };
}

const DOUYU_COLORS = [0xffffff, 0xff0000, 0x1e87f0, 0x7ac84b, 0xff7f00, 0x9b39f4, 0xff69b4];
function douyuPacket(message) {
  const body = Buffer.from(`${message}\0`);
  const header = Buffer.alloc(12);
  header.writeUInt32LE(body.length + 8, 0);
  header.writeUInt32LE(body.length + 8, 4);
  header.writeUInt16LE(689, 8);
  return Buffer.concat([header, body]);
}
function decodeSTT(message) {
  const fields = Object.create(null);
  for (const part of message.split('/')) {
    const separator = part.indexOf('@=');
    if (separator < 1) continue;
    const unescape = (value) => value.replace(/@S/g, '/').replace(/@A/g, '@');
    fields[unescape(part.slice(0, separator))] = unescape(part.slice(separator + 2));
  }
  return fields;
}
function createDouyuProtocol(config) {
  const roomId = numericId(config.roomId, 'room');
  const groupId = String(config.groupId ?? '-9999');
  if (!/^-?\d{1,19}$/.test(groupId)) throw new Error('Invalid live group identifier');
  let pending = Buffer.alloc(0);
  return {
    open() {
      pending = Buffer.alloc(0);
      return [douyuPacket(`type@=loginreq/roomid@=${roomId}/`), douyuPacket(`type@=joingroup/rid@=${roomId}/gid@=${groupId}/`)];
    },
    heartbeat() { return [douyuPacket('type@=mrkl/')]; },
    decode(data) {
      const result = emptyResult();
      const input = inputBuffer(data);
      if (!input || pending.length + input.length > MAX_DECODE_BYTES) { pending = Buffer.alloc(0); return result; }
      const bytes = pending.length ? Buffer.concat([pending, input]) : input;
      pending = Buffer.alloc(0);
      let offset = 0;
      let packets = 4096;
      while (offset < bytes.length && packets-- > 0) {
        if (bytes.length - offset < 12) { pending = Buffer.from(bytes.subarray(offset)); break; }
        const size = bytes.readUInt32LE(offset) + 4;
        if (size < 13 || size > MAX_PACKET_BYTES || bytes.readUInt32LE(offset + 4) !== size - 4) break;
        if (bytes.length - offset < size) { pending = Buffer.from(bytes.subarray(offset)); break; }
        const type = bytes.readUInt16LE(offset + 8);
        const body = bytes.subarray(offset + 12, offset + size);
        offset += size;
        if (type !== 690 || body.at(-1) !== 0) continue;
        const fields = decodeSTT(body.subarray(0, -1).toString('utf8'));
        if (fields.type === 'error') throw new Error('Douyu live auth failed');
        if (fields.type !== 'chatmsg') continue;
        appendChat(result.comments, fields.txt, DOUYU_COLORS[Number(fields.col)] ?? 0xffffff, 1);
      }
      return result;
    },
  };
}

// Tars/JCE values use tagged, variable-size integers and bounded nested structures.
class JceReader {
  constructor(bytes) { this.bytes = bytes; this.offset = 0; this.fields = 0; }
  take(size) {
    if (!Number.isInteger(size) || size < 0 || size > this.bytes.length - this.offset) throw new Error('Truncated JCE field');
    const bytes = this.bytes.subarray(this.offset, this.offset + size);
    this.offset += size;
    return bytes;
  }
  head() {
    if (++this.fields > MAX_FIELDS) throw new Error('Too many JCE fields');
    const head = this.take(1)[0];
    return { type: head & 15, tag: (head >> 4) === 15 ? this.take(1)[0] : head >> 4 };
  }
  count() {
    const { type } = this.head();
    const count = this.value(type, 0);
    if (!Number.isInteger(count) || count < 0 || count > MAX_FIELDS) throw new Error('Invalid JCE collection length');
    return count;
  }
  value(type, depth) {
    if (depth > MAX_DEPTH) throw new Error('JCE nesting limit exceeded');
    switch (type) {
      case 0: return this.take(1).readInt8();
      case 1: return this.take(2).readInt16BE();
      case 2: return this.take(4).readInt32BE();
      case 3: return this.take(8).readBigInt64BE();
      case 4: return this.take(4).readFloatBE();
      case 5: return this.take(8).readDoubleBE();
      case 6: return this.take(this.take(1)[0]).toString('utf8');
      case 7: return this.take(this.take(4).readUInt32BE()).toString('utf8');
      case 8: {
        const length = this.count();
        const values = new Map();
        for (let index = 0; index < length; index++) values.set(this.value(this.head().type, depth + 1), this.value(this.head().type, depth + 1));
        return values;
      }
      case 9: {
        const length = this.count();
        const values = [];
        for (let index = 0; index < length; index++) values.push(this.value(this.head().type, depth + 1));
        return values;
      }
      case 10: return this.struct(depth + 1, true);
      case 12: return 0;
      case 13: {
        if (this.head().type !== 0) throw new Error('Invalid JCE byte vector');
        const { type } = this.head();
        const length = this.value(type, depth + 1);
        if (!Number.isInteger(length) || length < 0 || length > MAX_PACKET_BYTES) throw new Error('Invalid JCE byte length');
        return this.take(length);
      }
      default: throw new Error('Invalid JCE field type');
    }
  }
  struct(depth = 0, terminated = false, command = false) {
    const fields = new Map();
    while (this.offset < this.bytes.length) {
      if (command && fields.has(0) && this.bytes[this.offset] >> 4 === 0 && (this.bytes[this.offset] & 15) !== 11) break;
      const { type, tag } = this.head();
      if (type === 11) {
        if (!terminated) throw new Error('Unexpected JCE struct end');
        return fields;
      }
      fields.set(tag, this.value(type, depth));
    }
    if (terminated) throw new Error('Truncated JCE struct');
    return fields;
  }
}
function readJce(bytes) {
  if (!Buffer.isBuffer(bytes) || bytes.length > MAX_PACKET_BYTES) return new Map();
  return new JceReader(bytes).struct();
}
function jceInt(tag, value) {
  const number = BigInt(value);
  if (number === 0n) return Buffer.from([(tag << 4) | 12]);
  let type, bytes;
  if (number >= -128n && number <= 127n) { type = 0; bytes = Buffer.alloc(1); bytes.writeInt8(Number(number)); }
  else if (number >= -32768n && number <= 32767n) { type = 1; bytes = Buffer.alloc(2); bytes.writeInt16BE(Number(number)); }
  else if (number >= -2147483648n && number <= 2147483647n) { type = 2; bytes = Buffer.alloc(4); bytes.writeInt32BE(Number(number)); }
  else { type = 3; bytes = Buffer.alloc(8); bytes.writeBigInt64BE(number); }
  return Buffer.concat([Buffer.from([(tag << 4) | type]), bytes]);
}
function jceString(tag, value) {
  const body = Buffer.from(String(value));
  if (body.length < 256) return Buffer.concat([Buffer.from([(tag << 4) | 6, body.length]), body]);
  const header = Buffer.alloc(5);
  header[0] = (tag << 4) | 7;
  header.writeUInt32BE(body.length, 1);
  return Buffer.concat([header, body]);
}
function jceBytes(tag, body) { return Buffer.concat([Buffer.from([(tag << 4) | 13, 0]), jceInt(0, body.length), body]); }
function huyaCommand(type, body) { return Buffer.concat([jceInt(0, type), jceBytes(1, body)]); }
function createHuyaProtocol(config) {
  const uid = numericId(config.uid ?? config.presenterUid, 'broadcaster');
  const channelId = numericId(config.channelId ?? 0, 'channel', { allowZero: true });
  const subChannelId = numericId(config.subChannelId ?? 0, 'subchannel', { allowZero: true });
  const decodeNotice = (bytes, comments) => {
    const notice = readJce(bytes);
    if (!(notice.get(0) instanceof Map)) return;
    const format = notice.get(6) instanceof Map ? notice.get(6) : notice.get(5);
    appendChat(comments, notice.get(3), format instanceof Map ? Number(format.get(0)) : 0xffffff, 1);
  };
  return {
    open() {
      const registration = Buffer.concat([
        jceInt(0, uid), jceInt(1, 1), jceString(2, ''), jceString(3, ''),
        jceInt(4, channelId), jceInt(5, subChannelId), jceInt(6, 0), jceInt(7, 0),
      ]);
      const groups = Buffer.concat([Buffer.from([9]), jceInt(0, 2), jceString(0, `live:${uid}`), jceString(0, `chat:${uid}`), jceString(1, '')]);
      return [huyaCommand(1, registration), huyaCommand(16, groups)];
    },
    heartbeat() { return [huyaCommand(5, jceInt(0, 0))]; },
    decode(data) {
      const result = emptyResult();
      const bytes = inputBuffer(data);
      if (!bytes || bytes.length > MAX_PACKET_BYTES) return result;
      try {
        const reader = new JceReader(bytes);
        while (reader.offset < bytes.length && result.comments.length < MAX_COMMENTS) {
          const command = reader.struct(0, false, true);
          const type = command.get(0);
          if (type !== 7 && type !== 22) continue;
          const push = readJce(command.get(1));
          if (type === 7 && Number(push.get(1)) === 1400) decodeNotice(push.get(2), result.comments);
          if (type === 22 && Array.isArray(push.get(1))) {
            for (const item of push.get(1)) {
              if (item instanceof Map && Number(item.get(0)) === 1400) decodeNotice(item.get(1), result.comments);
            }
          }
        }
      } catch { /* A malformed untrusted field is discarded without breaking later WS messages. */ }
      return result;
    },
  };
}

function createJsonProtocol() {
  return {
    open() { return []; },
    heartbeat() { return []; },
    decode(data) {
      const result = emptyResult();
      const bytes = inputBuffer(data);
      if (!bytes || bytes.length > MAX_PACKET_BYTES) return result;
      let payload;
      try { payload = JSON.parse(bytes.toString('utf8')); } catch { return result; }
      const entries = Array.isArray(payload) ? payload : Array.isArray(payload?.comments) ? payload.comments : [payload];
      for (const entry of entries.slice(0, MAX_COMMENTS)) {
        if (!entry || typeof entry !== 'object' || (entry.type && !['chat', 'chatmsg', 'danmaku'].includes(entry.type))) continue;
        appendChat(result.comments, entry.text, entry.color, entry.mode);
      }
      return result;
    },
  };
}

/** Build the platform handshake, heartbeat and decoder for one WebSocket connection. */
export function createLiveProtocol(config) {
  switch (config?.platform) {
    case 'bilibili': return createBilibiliProtocol(config);
    case 'douyu': return createDouyuProtocol(config);
    case 'huya': return createHuyaProtocol(config);
    case 'douyin': return createDouyinProtocol(config);
    case 'json': return createJsonProtocol();
    default: throw new Error(`Unsupported live platform: ${String(config?.platform ?? '')}`);
  }
}
