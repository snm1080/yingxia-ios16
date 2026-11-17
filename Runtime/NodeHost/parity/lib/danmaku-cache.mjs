import fs from 'node:fs/promises';
import path from 'node:path';
import { withCacheFileLock, sameCacheFile } from './cache-file-lock.mjs';

const queues = new Map();
// Only disposable, content-addressed copies live here. User imports remain at
// their original path and session indexes are managed by the native lifecycle.
export function pruneDanmakuCache(directory, { maxBytes = 64 * 1024 ** 2, maxAgeMs = 7 * 86400_000,
  now = Date.now(), keep = [] } = {}) {
  const previous = queues.get(directory) || Promise.resolve();
  const work = previous.catch(() => {}).then(async () => {
    const names = await fs.readdir(directory).catch(error => { if (error.code === 'ENOENT') return []; throw error; });
    const protectedNames = new Set(keep.map(id => `${id}.xml`));
    const files = [];
    for (const name of names) {
      if (!/^[a-f\d]{64}\.xml(?:\.[a-f\d-]+\.tmp)?$/.test(name)) continue;
      const file = path.join(directory, name), stat = await fs.lstat(file).catch(() => null);
      if (!stat?.isFile() || stat.isSymbolicLink()) continue;
      files.push({ name, file, bytes: stat.size, time: stat.mtimeMs, stat });
    }
    files.sort((a, b) => a.time - b.time);
    let bytes = files.reduce((sum, file) => sum + file.bytes, 0), removed = 0;
    for (const file of files) {
      if (protectedNames.has(file.name)) continue;
      const temporary = file.name.endsWith('.tmp');
      if (temporary && now - file.time < 3600_000) continue;
      if (!temporary && now - file.time < maxAgeMs && bytes <= maxBytes) continue;
      await withCacheFileLock(file.file, async () => {
        const current = await fs.lstat(file.file).catch(() => null);
        if (!sameCacheFile(current, file.stat)) return;
        await fs.rm(file.file, { force: true }); bytes -= file.bytes; removed++;
      });
    }
    return { bytes, removed };
  });
  queues.set(directory, work);
  void work.finally(() => { if (queues.get(directory) === work) queues.delete(directory); }).catch(() => {});
  return work;
}
