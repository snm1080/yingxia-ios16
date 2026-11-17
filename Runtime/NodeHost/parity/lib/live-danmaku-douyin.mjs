import { gunzipSync } from 'node:zlib';

// The webcast wire schema uses PushFrame(2=logId, 6=encoding, 7=type,
// 8=payload), Response(1=messages, 5=internalExt, 9=needAck), and
// ChatMessage(3=content, 6=fullScreenTextColor). This is an independently
// implemented minimal protobuf reader, requiring no generated schema/runtime.
const MAX_PACKET = 4 * 1024 * 1024;
const MAX_FIELDS = 32768;
const MAX_MESSAGES = 2048;
const MAX_COMMENTS = 512;
const MAX_TEXT_BYTES = 4096;
const empty = () => ({ comments: [], replies: [] });

function varint(data, cursor) {
  let value = 0n;
  for (let shift = 0n; shift < 70n; shift += 7n) {
    if (cursor.offset >= data.length) throw new Error('Truncated protobuf');
    const byte = data[cursor.offset++];
    value |= BigInt(byte & 127) << shift;
    if (!(byte & 128)) return value;
  }
  throw new Error('Invalid protobuf varint');
}

function fields(data, budget, repeated = 0) {
  const output = new Map();
  const cursor = { offset: 0 };
  while (cursor.offset < data.length) {
    if (--budget.fields < 0) throw new Error('Too many protobuf fields');
    const rawTag = varint(data, cursor);
    if (rawTag > 0xffffffffn) throw new Error('Invalid protobuf field tag');
    const tag = Number(rawTag);
    const number = tag >>> 3;
    const wire = tag & 7;
    if (!number) throw new Error('Invalid protobuf field');
    const retain = (output.get(number)?.length || 0) < (number === repeated ? MAX_MESSAGES : 1);
    let value;
    if (wire === 0) value = varint(data, cursor);
    else if (wire === 2) {
      const length = Number(varint(data, cursor));
      if (!Number.isSafeInteger(length) || length > data.length - cursor.offset) throw new Error('Truncated protobuf bytes');
      if (retain) value = data.subarray(cursor.offset, cursor.offset + length);
      cursor.offset += length;
    } else if (wire === 1 || wire === 5) {
      const length = wire === 1 ? 8 : 4;
      if (length > data.length - cursor.offset) throw new Error('Truncated protobuf number');
      cursor.offset += length;
      continue;
    } else throw new Error('Unsupported protobuf wire type');
    if (retain) {
      if (!output.has(number)) output.set(number, []);
      output.get(number).push(value);
    }
  }
  return output;
}

const bytes = (map, number) => {
  const value = map.get(number)?.[0];
  return Buffer.isBuffer(value) ? value : Buffer.alloc(0);
};
const string = (map, number) => bytes(map, number).toString('utf8');
const uint = (map, number) => typeof map.get(number)?.[0] === 'bigint' ? map.get(number)[0] : 0n;

function encodeVarint(value) {
  let remaining = BigInt(value);
  const result = [];
  do {
    const byte = Number(remaining & 127n);
    remaining >>= 7n;
    result.push(byte | (remaining ? 128 : 0));
  } while (remaining);
  return Buffer.from(result);
}

function byteField(number, value) {
  const data = Buffer.isBuffer(value) ? value : Buffer.from(value);
  return Buffer.concat([encodeVarint(number * 8 + 2), encodeVarint(data.length), data]);
}

export function createDouyinProtocol(_config = {}) {
  return {
    open: () => [],
    heartbeat: () => [byteField(7, 'hb')],
    decode(data) {
      try {
        if (!data || data.byteLength > MAX_PACKET) return empty();
        const input = Buffer.isBuffer(data) ? data : data instanceof Uint8Array ? Buffer.from(data.buffer, data.byteOffset, data.byteLength) : null;
        if (!input?.length || input.length > MAX_PACKET) return empty();
        const budget = { fields: MAX_FIELDS };
        const frame = fields(input, budget);
        const type = string(frame, 7);
        if (type && !['msg', 'message'].includes(type)) return empty();
        let payload = bytes(frame, 8);
        if (!payload.length) return empty();
        const encoding = string(frame, 6);
        // Live servers also omit payloadEncoding while retaining gzip magic.
        if (encoding === 'gzip' || (payload[0] === 0x1f && payload[1] === 0x8b)) {
          payload = gunzipSync(payload, { maxOutputLength: MAX_PACKET });
        } else if (encoding && encoding !== 'identity') return empty();
        const response = fields(payload, budget, 1);
        const replies = uint(response, 9) === 0n ? [] : [Buffer.concat([
          encodeVarint(16), encodeVarint(uint(frame, 2)), byteField(7, 'ack'), byteField(8, bytes(response, 5)),
        ])];
        const comments = [];
        for (const raw of response.get(1) || []) {
          if (comments.length >= MAX_COMMENTS) break;
          if (!Buffer.isBuffer(raw)) continue;
          try {
            const message = fields(raw, budget);
            if (string(message, 1) !== 'WebcastChatMessage') continue;
            const chat = fields(bytes(message, 2), budget);
            const content = bytes(chat, 3);
            if (content.length > MAX_TEXT_BYTES) continue;
            const text = content.toString('utf8').trim();
            if (!text || Buffer.byteLength(text, 'utf8') > MAX_TEXT_BYTES) continue;
            const color = string(chat, 6).match(/^#?([0-9a-f]{6})$/i)?.[1];
            comments.push({ text, color: color ? parseInt(color, 16) : 0xffffff, mode: 1 });
          } catch { /* One damaged chat must not drop the response ack. */ }
        }
        return { comments, replies };
      } catch { return empty(); }
    },
  };
}
