import { AppError } from './errors.mjs';

export class RequestBudget {
  constructor({ perResource = 1 } = {}) { this.slots = new Map(); this.closed = false; this.perResource = Math.max(1, Math.min(2, perResource)); }
  get activeCount() { return [...this.slots.values()].reduce((count, slot) => count + slot.active, 0); }
  acquire(key, { signal, speculative = false } = {}) {
    if (this.closed) return Promise.reject(new AppError('BUDGET_CLOSED', '媒体读取已关闭'));
    if (signal?.aborted) return Promise.reject(signal.reason);
    let slot = this.slots.get(key);
    if (!slot) { slot = { active: 0, queue: [] }; this.slots.set(key, slot); }
    if (speculative && (slot.active || slot.queue.length)) return Promise.resolve(null);
    return new Promise((resolve, reject) => {
      const entry = { resolve, reject, signal, abort: null };
      entry.abort = () => { slot.queue = slot.queue.filter(item => item !== entry); reject(signal.reason); this.prune(key, slot); };
      signal?.addEventListener('abort', entry.abort, { once: true });
      slot.queue.push(entry); this.pump(key, slot);
    });
  }
  prune(key, slot) { if (!slot.active && !slot.queue.length) this.slots.delete(key); }
  pump(key, slot) {
    if (slot.active >= this.perResource || this.closed) return;
    const entry = slot.queue.shift(); if (!entry) { this.prune(key, slot); return; }
    entry.signal?.removeEventListener('abort', entry.abort);
    if (entry.signal?.aborted) { entry.reject(entry.signal.reason); this.pump(key, slot); return; }
    slot.active++; let released = false;
    entry.resolve({ release: () => { if (released) return; released = true; slot.active--; this.pump(key, slot); this.prune(key, slot); } });
  }
  close() {
    this.closed = true;
    for (const slot of this.slots.values()) for (const entry of slot.queue.splice(0)) {
      entry.signal?.removeEventListener('abort', entry.abort); entry.reject(new AppError('BUDGET_CLOSED', '媒体读取已关闭'));
    }
    this.slots.clear();
  }
}
