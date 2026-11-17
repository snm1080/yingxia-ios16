import fs from 'node:fs/promises';

// One producer reads the connection already selected by the subscription. The
// decoder consumes its bounded disk queue independently, so its small packet
// buffer does not also limit the application's 1–4 GiB forward cache.
export class ForwardMediaReader {
  constructor(cache, resource, upstream, meta, signal) {
    Object.assign(this, { cache, resource, upstream, meta });
    this.owner = resource.owner;
    this.revision = this.owner.cacheRevision;
    this.controller = new AbortController();
    this.signal = AbortSignal.any([signal, this.controller.signal]);
    this.nodes = []; this.waiters = new Set(); this.done = false; this.error = null;
    this.owner.forwardReaders.add(this);
    this.finished = this.produce().catch(error => { this.error = error; }).finally(() => {
      this.done = true; this.wake();
    });
  }

  wake() { for (const wake of this.waiters) wake(); this.waiters.clear(); }
  async wait() {
    this.signal.throwIfAborted();
    await new Promise((resolve, reject) => {
      const finish = () => { this.signal.removeEventListener('abort', abort); this.waiters.delete(finish); resolve(); };
      const abort = () => { this.waiters.delete(finish); reject(this.signal.reason); };
      this.waiters.add(finish); this.signal.addEventListener('abort', abort, { once: true });
      if (this.signal.aborted) abort();
    });
  }

  async allocate(start) {
    const cache = this.cache, owner = this.owner;
    const caching = owner.enabled && this.revision === owner.cacheRevision;
    const maximum = caching ? Math.min(owner.maxBytes, cache.videoMaxBytes) : cache.blockBytes;
    const size = Math.max(1, Math.min(cache.blockBytes - start % cache.blockBytes,
      this.meta.end - start + 1, maximum || cache.blockBytes));
    // A tail/seek opened by libavformat must get its first bytes even while
    // the previous input pins a full disk window. At most one extra RAM block
    // per active request is needed; put() still enforces the disk limit.
    await cache.reserveForward(owner, size, this.signal, () => this.nodes.length === 0, this.revision);
    const node = { start, capacity: size, length: 0, consumed: 0, sealed: false,
      data: Buffer.allocUnsafe(size), revision: this.revision, reserved: true };
    this.nodes.push(node); this.wake(); return node;
  }

  async seal(node) {
    if (!node || node.sealed) return;
    node.block = await this.cache.put(this.resource, node.start, node.data.subarray(0, node.length), node.revision, { pin: true });
    node.sealed = true;
    // Disk owns unread blocks; RAM contains only the current network block and
    // the decoder's current read. A failed write stays a bounded memory queue.
    if (node.block) node.data = null;
    this.wake();
  }

  async produce() {
    const iterator = this.upstream.response.body?.[Symbol.asyncIterator]();
    let position = this.meta.start, node;
    try {
      if (!iterator) return;
      while (position <= this.meta.end) {
        if (!node) node = await this.allocate(position);
        const timer = setTimeout(() => this.upstream.controller.abort(), this.cache.idleTimeoutMs);
        timer.unref?.();
        let next;
        try { next = await iterator.next(); } finally { clearTimeout(timer); }
        this.signal.throwIfAborted();
        if (next.done) break;
        const bytes = Buffer.from(next.value);
        this.owner.networkBytes += bytes.length;
        if (position + bytes.length > this.meta.end + 1) throw new Error('invalid media length');
        let offset = 0;
        while (offset < bytes.length) {
          this.signal.throwIfAborted();
          if (!node) node = await this.allocate(position);
          const length = Math.min(node.capacity - node.length, bytes.length - offset);
          bytes.copy(node.data, node.length, offset, offset + length);
          node.length += length; offset += length; position += length; this.wake();
          if (node.length === node.capacity) { await this.seal(node); node = null; }
        }
      }
      if (position !== this.meta.end + 1) throw new Error('truncated media response');
    } finally {
      // Header/tail probes are frequently interrupted mid-block. Retain their
      // already received bytes for a subsequent seek, just like ordinary reads.
      if (node?.length) await this.seal(node);
      else if (node) { this.releaseNode(node); this.nodes = this.nodes.filter(value => value !== node); }
      this.upstream.controller.abort();
      await iterator?.return?.().catch(() => {});
      this.upstream.releaseBudget?.();
    }
  }

  releaseNode(node) {
    if (!node.reserved) return;
    node.reserved = false;
    this.owner.forwardBytes = Math.max(0, this.owner.forwardBytes - node.capacity);
    if (node.block) {
      node.block.pins = Math.max(0, (node.block.pins || 0) - 1);
      if (!this.owner.enabled || node.revision !== this.owner.cacheRevision || this.owner.bytes > this.owner.maxBytes)
        void this.cache.serial(async () => {
          if (!node.block.pins) await this.cache.remove(this.owner, node.block);
        }).catch(() => {});
    }
    this.cache.wakeForward();
  }

  async *body() {
    try {
      while (true) {
        this.signal.throwIfAborted();
        const node = this.nodes[0];
        if (!node) {
          if (this.done) { if (this.error) throw this.error; return; }
          await this.wait(); continue;
        }
        if (node.consumed < node.length) {
          const bytes = node.data || await fs.readFile(node.block.file);
          const end = node.length;
          yield bytes.subarray(node.consumed, end);
          node.consumed = end;
        }
        if (node.sealed && node.consumed === node.length) { this.releaseNode(node); this.nodes.shift(); }
        else if (node.consumed >= node.length) await this.wait();
      }
    } finally {
      this.controller.abort(); this.upstream.controller.abort(); this.wake(); this.cache.wakeForward();
      await this.finished;
      for (const node of this.nodes) this.releaseNode(node);
      this.nodes = []; this.owner.forwardReaders.delete(this);
    }
  }
}
