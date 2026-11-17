import fs from 'node:fs/promises';
import { createReadStream } from 'node:fs';

export const DANMAKU_INDEX_FORMAT = 'wincat-danmaku-index';
export const DANMAKU_CHUNK_COUNT = 512;
export const DANMAKU_CHUNK_BYTES = 512 * 1024;

// One owned file: a small JSON header followed by independently readable JSON
// arrays. Offsets are relative to the byte immediately after the header newline.
// The normalized list is temporary; native playback never parses that whole list.
export async function writeDanmakuIndex(file, comments, { signal } = {}) {
  const body = `${file}.body`, partial = `${file}.partial`;
  let output;
  try {
    output = await fs.open(body, 'wx', 0o600);
    const chunks = [];
    let batch = [], bytes = 2, offset = 0, first = 1;
    const flush = async () => {
      if (!batch.length) return;
      signal?.throwIfAborted();
      const data = Buffer.from(`[${batch.join(',')}]\n`);
      chunks.push({ offset, bytes: data.length - 1, count: batch.length, first,
        time: comments[first - 1].time, end: comments[first + batch.length - 2].time });
      await output.write(data);
      offset += data.length; first += batch.length; batch = []; bytes = 2;
    };
    for (const comment of comments) {
      const value = JSON.stringify(comment), size = Buffer.byteLength(value) + 1;
      if (size + 1 > 4 * 1024 * 1024) throw new Error('单条高级弹幕数据超过 4 MiB，无法安全加载');
      if (batch.length && (batch.length >= DANMAKU_CHUNK_COUNT || bytes + size > DANMAKU_CHUNK_BYTES)) await flush();
      batch.push(value); bytes += size;
    }
    await flush();
    await output.close(); output = undefined;
    const manifest = { format: DANMAKU_INDEX_FORMAT, version: 1, count: comments.length,
      decorated: comments.some(item => ['badge', 'highlight', 'celebrate'].includes(item.effect?.kind)), chunks };
    const header = Buffer.from(JSON.stringify(manifest) + '\n');
    if (header.length > 1024 * 1024) throw new Error('弹幕索引过大，无法安全加载');
    output = await fs.open(partial, 'wx', 0o600);
    await output.write(header);
    for await (const data of createReadStream(body)) {
      signal?.throwIfAborted();
      await output.write(data);
    }
    await output.close(); output = undefined;
    signal?.throwIfAborted();
    await fs.rename(partial, file);
    return manifest;
  } finally {
    await output?.close();
    await Promise.all([fs.rm(body, { force: true }), fs.rm(partial, { force: true })]);
  }
}
