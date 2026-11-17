import fs from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

export async function atomicWrite(file, data) {
  await fs.mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
  const temporary = `${file}.${randomUUID()}.tmp`;
  try {
    await fs.writeFile(temporary, data, { mode: 0o600, flush: true });
    await fs.rename(temporary, file);
  } finally {
    await fs.rm(temporary, { force: true });
  }
}

export class JsonStore {
  #queue = Promise.resolve();
  constructor(file, initial, { normalize, recover = false } = {}) {
    this.file = file;
    this.initial = structuredClone(initial);
    this.normalize = normalize;
    this.recover = recover;
    this.ready = this.#load();
    // Stores load eagerly, but their first consumer may arrive after startup.
    // Keep failures observable through read/update without an unhandled rejection.
    this.ready.catch(() => {});
  }
  async #load() {
    let bytes;
    try {
      bytes = await fs.readFile(this.file);
      this.data = JSON.parse(bytes.toString('utf8'));
    } catch (error) {
      if (error.code === 'ENOENT') this.data = structuredClone(this.initial);
      else if (this.recover && error instanceof SyntaxError) await this.#recover(bytes);
      else throw new Error(`数据文件无法读取：${path.basename(this.file)}`, { cause: error });
    }
    if (this.normalize?.(this.data)) await atomicWrite(this.file, `${JSON.stringify(this.data, null, 2)}\n`);
  }
  async #recover(bytes) {
    let restored;
    try {
      const backup = JSON.parse(await fs.readFile(`${this.file}.bak`, 'utf8'));
      // A syntactically valid but incompatible backup cannot restore a library.
      if (backup && Object.keys(this.initial).every(key =>
        Array.isArray(this.initial[key]) ? Array.isArray(backup[key]) : Object.hasOwn(backup, key)))
        restored = backup;
    } catch (error) {
      if (error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw error;
    }
    if (!restored) throw new Error(`数据文件无法读取：${path.basename(this.file)}；没有可用备份，原文件已保留，请恢复备份后重试`);
    const preserved = `${this.file}.corrupt-${Date.now()}-${randomUUID()}.bak`;
    await atomicWrite(preserved, bytes);
    await atomicWrite(this.file, `${JSON.stringify(restored, null, 2)}\n`);
    this.data = restored;
  }
  async read() {
    await this.ready;
    await this.#queue;
    return structuredClone(this.data);
  }
  async readKey(key) {
    await this.ready;
    await this.#queue;
    return Object.hasOwn(this.data, key) ? structuredClone(this.data[key]) : undefined;
  }
  // For recoverable caches only: forget resident data while leaving its disk
  // copy intact. Serialize with writes without cloning the populated database.
  discardMemory() {
    const action = this.#queue.then(async () => {
      await this.ready;
      this.data = structuredClone(this.initial);
    });
    this.#queue = action.catch(() => {});
    return action;
  }
  update(mutate) {
    const action = this.#queue.then(async () => {
      await this.ready;
      const next = structuredClone(this.data);
      const result = await mutate(next);
      if (this.recover) await atomicWrite(`${this.file}.bak`, `${JSON.stringify(this.data, null, 2)}\n`);
      await atomicWrite(this.file, `${JSON.stringify(next, null, 2)}\n`);
      this.data = next;
      return result;
    });
    this.#queue = action.catch(() => {});
    return action;
  }
}

export async function readLimited(file, maxBytes) {
  const handle = await fs.open(file, 'r');
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || stat.size > maxBytes) throw new Error('文件过大或不是普通文件');
    const chunks = [];
    let count = 0;
    for await (const chunk of handle.createReadStream({ autoClose: false })) {
      count += chunk.length;
      if (count > maxBytes) throw new Error('文件超过大小限制');
      chunks.push(chunk);
    }
    return Buffer.concat(chunks);
  } finally {
    await handle.close();
  }
}
