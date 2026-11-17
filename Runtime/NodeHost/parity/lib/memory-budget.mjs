// Conservative payload estimate without serializing or copying the entire tree.
export function approximateBytes(value, limit = Infinity) {
  const seen = new Set(), pending = [value];
  let bytes = 0;
  while (pending.length && bytes <= limit) {
    const item = pending.pop();
    if (typeof item === 'string') bytes += item.length * 2 + 16;
    else if (item && typeof item === 'object') {
      if (seen.has(item)) continue;
      seen.add(item); bytes += 32;
      if (ArrayBuffer.isView(item)) bytes += item.byteLength;
      else if (Array.isArray(item)) {
        bytes += item.length * 8;
        if (bytes <= limit) for (const value of item) pending.push(value);
      }
      else for (const key of Object.keys(item)) { bytes += key.length * 2 + 16; pending.push(item[key]); }
    } else bytes += 8;
  }
  return bytes;
}

export class BudgetCache {
  constructor({ maxEntries, maxBytes, sizeOf = approximateBytes }) {
    Object.assign(this, { maxEntries, maxBytes, sizeOf });
    this.entries = new Map(); this.bytes = 0;
  }
  get size() { return this.entries.size; }
  has(key) { return this.entries.has(key); }
  get(key) {
    const entry = this.entries.get(key);
    if (!entry) return undefined;
    this.entries.delete(key); this.entries.set(key, entry);
    return entry.value;
  }
  set(key, value) {
    const bytes = this.sizeOf(value, this.maxBytes);
    this.delete(key);
    if (bytes > this.maxBytes) return this;
    this.entries.set(key, { value, bytes }); this.bytes += bytes;
    while (this.size > this.maxEntries || this.bytes > this.maxBytes) this.delete(this.entries.keys().next().value);
    return this;
  }
  delete(key) {
    const entry = this.entries.get(key);
    if (!entry) return false;
    this.bytes -= entry.bytes; return this.entries.delete(key);
  }
  clear() { this.entries.clear(); this.bytes = 0; }
  keys() { return this.entries.keys(); }
  resize({ maxEntries = this.maxEntries, maxBytes = this.maxBytes } = {}) {
    this.maxEntries = Math.max(0, maxEntries);
    this.maxBytes = Math.max(0, maxBytes);
    while (this.size && (this.size > this.maxEntries || this.bytes > this.maxBytes)) this.delete(this.entries.keys().next().value);
    return this;
  }
}

export function appendWithinBudget(before, after, { maxItems = 1200, maxBytes = 4 * 1024 ** 2 } = {}) {
  const bytes = approximateBytes(before, maxBytes) + approximateBytes(after, maxBytes);
  const exceeds = before.length + after.length > maxItems || bytes > maxBytes;
  // Do not split a provider page and silently lose its remaining items.
  // A declined next page is fetched again in the next browsing batch.
  if (before.length && exceeds) return { items: before, limited: true, accepted: false };
  const items = [...before, ...after];
  return { items, limited: exceeds || items.length >= maxItems, accepted: true };
}

export function trimNavigation(entries, { maxEntries = 40, maxBytes = 32 * 1024 ** 2 } = {}) {
  const retained = entries.slice(-maxEntries);
  while (retained.length > 1 && approximateBytes(retained, maxBytes) > maxBytes) retained.shift();
  return retained;
}
