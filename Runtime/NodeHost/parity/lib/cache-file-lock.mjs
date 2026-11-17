import path from 'node:path';

const locks = new Map();

// Only a single file's short filesystem mutations share this lock. Directory
// scans and network requests remain independent of foreground cache reads.
export function withCacheFileLock(file, action) {
  const key = path.resolve(file), previous = locks.get(key) || Promise.resolve();
  const work = previous.catch(() => {}).then(action);
  locks.set(key, work);
  void work.finally(() => { if (locks.get(key) === work) locks.delete(key); }).catch(() => {});
  return work;
}

export function sameCacheFile(current, previous) {
  return current && ['dev', 'ino', 'size', 'mtimeMs', 'ctimeMs'].every(key => current[key] === previous[key]);
}
