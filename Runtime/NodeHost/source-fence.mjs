// Authenticated callers use one UUID per source operation. Completion means the
// actual handler/HTTP cleanup finished, including work after a response closed.
export class SourceFence {
    constructor({ maximum = 256, retainedMs = 600_000 } = {}) {
        this.maximum = maximum;
        this.retainedMs = retainedMs;
        this.entries = new Map();
    }
    valid(id) { return typeof id === 'string' && /^[0-9a-f]{8}-[0-9a-f-]{27}$/i.test(id); }
    prune() {
        const now = Date.now();
        for (const [id, entry] of this.entries) if (entry.done && now - entry.at > this.retainedMs) this.entries.delete(id);
    }
    begin(id, controller) {
        if (!this.valid(id)) throw new Error('Invalid source operation');
        this.prune();
        if (this.entries.has(id)) throw new Error('The source operation already ended or was cancelled');
        if (this.entries.size >= this.maximum) throw new Error('The source runtime is busy. Retry after the current operations finish.');
        let finish;
        const completed = new Promise(resolve => { finish = resolve; });
        const entry = { controller, completed, finish, registered: true, done: false, at: Date.now() };
        this.entries.set(id, entry);
        return () => {
            if (entry.done) return;
            entry.done = true; entry.at = Date.now(); entry.controller = null; entry.finish();
        };
    }
    async wait(id, cancel) {
        if (!this.valid(id)) throw new Error('Invalid source operation');
        this.prune();
        let entry = this.entries.get(id);
        if (!entry) {
            // Cancellation can arrive before a disconnected original POST is parsed.
            // Retain a tombstone so that late original input can never start a worker.
            if (this.entries.size >= this.maximum) throw new Error('The source runtime is busy. Retry after the current operations finish.');
            entry = { done: true, at: Date.now(), completed: Promise.resolve() };
            this.entries.set(id, entry);
        }
        if (cancel && !entry.done) entry.controller.abort();
        await entry.completed;
        // Registered operations have no late unparsed original POST: acknowledgement
        // retires their record. Unknown cancellation tombstones remain bounded/retained.
        if (entry.registered && this.entries.get(id) === entry) this.entries.delete(id);
        return { completed: true };
    }
}
