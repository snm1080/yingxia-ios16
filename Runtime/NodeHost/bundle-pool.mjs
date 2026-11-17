// Keep only a small set of idle source workers. Active source HTTP handlers,
// media proxies, configuration pages and sign-ins retain their worker leases.
export class BundlePool {
    constructor({ idleLimit = 4, maximum = 8, maximumPending = 16, waitMs = 25_000,
        idleMs = 120_000, searchWidth = 8, searchBundleLimit = 2, log = () => {} } = {}) {
        Object.assign(this, { idleLimit, maximum, maximumPending, waitMs, idleMs, searchWidth, searchBundleLimit, log });
        this.entries = new Map();
        this.startups = 0;
        this.retiring = null;
        this.trimRequested = false;
        this.waiters = new Set();
        this.resident = 0;
        this.peak = 0;
        this.searches = 0;
        this.searchPending = 0;
        this.searchBundles = new Map();
        this.searchQueue = [];
        this.timer = setInterval(() => this.trim().catch(error => log('CATPAW_POOL', String(error))), 30_000);
        this.timer.unref();
    }
    async acquire(key, create, signal) {
        signal?.throwIfAborted();
        let entry = this.entries.get(key);
        if (entry?.controller.signal.aborted && !entry.instance) { this.remove(entry); entry = null; }
        if (!entry) {
            if ([...this.entries.values()].filter(value => !value.instance).length >= this.maximumPending)
                throw new Error('The source runtime is busy. Wait for the active source requests.');
            entry = { key, users: 0, instance: null, lastUsed: Date.now(), pending: null, retiring: false,
                occupied: false, controller: new AbortController(), creating: false };
            this.entries.set(key, entry);
            // A remote config load must not serialize every other cold source. Keep
            // two startup slots, independent of the hard resident worker budget.
            entry.pending = Promise.resolve().then(async () => {
                await this.acquireStartup(entry.controller.signal);
                try {
                    if (entry.users === 0) throw new Error('The source request was cancelled');
                    await this.room(entry);
                    entry.controller.signal.throwIfAborted();
                    entry.creating = true;
                    entry.instance = await create(() => this.remove(entry));
                    entry.instance.exited.then(() => { this.remove(entry); this.releaseResident(entry); });
                    return entry.instance;
                } finally { this.startups -= 1; this.changed(); }
            }).catch(error => { this.remove(entry); this.releaseResident(entry); throw error; });
            // Observe startup rejection even if its client disconnects first.
            entry.pending.catch(() => {});
        }
        entry.users += 1;
        let instance;
        try {
            instance = await this.wait(entry.pending, signal);
            signal?.throwIfAborted();
            if (instance.closed) throw instance.stopped();
        } catch (error) {
            entry.users -= 1; entry.lastUsed = Date.now();
            const drainStartup = entry.users === 0 && entry.creating && !entry.instance && signal?.aborted;
            if (entry.users === 0 && !entry.instance && !entry.creating) entry.controller.abort();
            this.changed();
            if (drainStartup) {
                // The last cancelled caller still owns the actual cold load. Its
                // source fence must retain admission through startup or failed-start
                // cleanup. Queued work and callers with a surviving owner exit at once.
                await entry.pending.catch(() => {});
                this.trim().catch(error => this.log('CATPAW_POOL', String(error)));
            }
            throw error;
        }
        let released = false;
        return { instance, release: async () => {
            if (released) return;
            released = true; entry.users -= 1; entry.lastUsed = Date.now(); this.changed();
            // Release source ownership immediately. Idle retirement is pool maintenance;
            // its resident lease remains held until actual exit, outside the search fence.
            this.trim().catch(error => this.log('CATPAW_POOL', String(error)));
        } };
    }
    async acquireStartup(signal) {
        while (this.startups >= 2) {
            signal.throwIfAborted();
            await this.changedWithin(1000, signal);
        }
        signal.throwIfAborted(); this.startups += 1;
    }
    async acquireSearch(key, signal) {
        signal?.throwIfAborted();
        if (this.searchPending >= this.maximumPending) throw new Error('The source runtime is busy. Wait for the active searches.');
        return await new Promise((resolve, reject) => {
            const entry = { key };
            const remove = error => {
                const index = this.searchQueue.indexOf(entry);
                if (index < 0) return;
                this.searchQueue.splice(index, 1); this.searchPending -= 1;
                entry.finish(error); this.drainSearches();
            };
            const abort = () => remove(signal.reason);
            const timer = setTimeout(() => remove(new Error('The source runtime is busy. Retry after the active searches finish.')), this.waitMs);
            timer.unref();
            entry.finish = (error, release) => {
                clearTimeout(timer); signal?.removeEventListener('abort', abort);
                error ? reject(error) : resolve(release);
            };
            this.searchPending += 1; this.searchQueue.push(entry);
            signal?.addEventListener('abort', abort, { once: true });
            if (signal?.aborted) abort(); else this.drainSearches();
        });
    }
    drainSearches() {
        while (this.searchQueue.length && this.searches < this.searchWidth) {
            const entry = this.searchQueue[0];
            // FIFO prevents endless warm refills from starving another bundle. A
            // new identity waits only for actual searches to drain, never for trim.
            if (!this.searchBundles.has(entry.key) && this.searchBundles.size >= this.searchBundleLimit) return;
            this.searchQueue.shift(); this.searchPending -= 1; this.searches += 1;
            this.searchBundles.set(entry.key, (this.searchBundles.get(entry.key) || 0) + 1);
            let released = false;
            entry.finish(null, () => {
                if (released) return;
                released = true; this.searches -= 1;
                const remaining = this.searchBundles.get(entry.key) - 1;
                if (remaining) this.searchBundles.set(entry.key, remaining); else this.searchBundles.delete(entry.key);
                this.drainSearches(); this.changed();
            });
        }
    }
    remove(entry) {
        // An old worker's late exit cannot remove the new entry created for this key.
        if (this.entries.get(entry.key) === entry) this.entries.delete(entry.key);
        this.changed();
    }
    releaseResident(entry) {
        if (!entry.occupied) return;
        entry.occupied = false; this.resident -= 1; this.changed(); this.report();
    }
    idle(entry, now = Date.now()) {
        const instance = entry.instance;
        return !!instance && !entry.retiring && !instance.closed && entry.users === 0
            && !instance.playbackPins?.size
            && instance.pending.size === 0 && !instance.relistening && !instance.proxyUpdate
            && (instance.activity?.active || 0) === 0
            && Math.max(instance.loginUntil || 0, instance.playbackUntil || 0, instance.pageUntil || 0) <= now;
    }
    async room(entry) {
        const signal = entry.controller.signal;
        const deadline = Date.now() + this.waitMs;
        while (this.resident >= this.maximum) {
            signal?.throwIfAborted();
            const idle = [...this.entries.values()].filter(entry => this.idle(entry))
                .sort((a, b) => a.lastUsed - b.lastUsed)[0];
            if (idle) { await this.retire(idle); continue; }
            const remaining = deadline - Date.now();
            if (remaining <= 0) throw new Error('The source runtime is busy. Stop another active source or retry shortly.');
            await this.changedWithin(Math.min(remaining, 1000), signal);
        }
        // Reserve before returning from this async method: simultaneous startup
        // continuations cannot both observe the last free slot and oversubscribe it.
        signal.throwIfAborted();
        this.resident += 1; entry.occupied = true; this.peak = Math.max(this.peak, this.resident);
        this.report();
    }
    async trim() {
        // Coalesce release bursts into one maintenance task. Actual termination
        // stays serial and retains resident accounting until worker exit.
        this.trimRequested = true;
        if (this.retiring) return this.retiring;
        this.retiring = (async () => {
            do {
                this.trimRequested = false;
                const now = Date.now();
                const idle = [...this.entries.values()].filter(entry => this.idle(entry, now))
                    .sort((a, b) => a.lastUsed - b.lastUsed);
                for (let index = 0; index < idle.length; index++) {
                    if (idle.length - index <= this.idleLimit && now - idle[index].lastUsed < this.idleMs) break;
                    if (this.idle(idle[index])) await this.retire(idle[index]);
                }
            } while (this.trimRequested);
        })().finally(() => { this.retiring = null; });
        return this.retiring;
    }
    async retire(entry) {
        if (entry.retiring || !this.idle(entry)) return;
        entry.retiring = true; this.remove(entry);
        try { await entry.instance.terminate(); }
        finally { this.releaseResident(entry); }
    }
    changed() { for (const wake of this.waiters) wake(); this.waiters.clear(); }
    changedWithin(ms, signal) {
        return new Promise((resolve, reject) => {
            const cleanup = () => { clearTimeout(timer); this.waiters.delete(wake); signal?.removeEventListener('abort', abort); };
            const wake = () => { cleanup(); resolve(); };
            const abort = () => { cleanup(); reject(signal.reason); };
            const timer = setTimeout(wake, ms); timer.unref(); this.waiters.add(wake);
            signal?.addEventListener('abort', abort, { once: true });
            if (signal?.aborted) abort();
        });
    }
    wait(pending, signal) {
        if (!signal) return pending;
        return new Promise((resolve, reject) => {
            const abort = () => { signal.removeEventListener('abort', abort); reject(signal.reason); };
            signal.addEventListener('abort', abort, { once: true });
            if (signal.aborted) abort();
            pending.then(value => { signal.removeEventListener('abort', abort); resolve(value); },
                error => { signal.removeEventListener('abort', abort); reject(error); });
        });
    }
    report() { this.log('CATPAW_POOL', `resident=${this.resident} peak=${this.peak} entries=${this.entries.size}`); }
}
