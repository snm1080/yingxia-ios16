import os from 'node:os';
import { Worker } from 'node:worker_threads';
import { log, thrownText } from './diagnostics.mjs';

// Match the upstream override while rejecting values V8 cannot use as a limit.
export function bundleHeapLimit(memory = os.totalmem(), override = process.env.YINGXIA_NODE_HEAP_MB) {
    const requested = Number(override);
    return Number.isFinite(requested) && requested >= 1 ? Math.round(requested)
        : Math.round(Math.min(768, Math.max(256, memory / 2 ** 20 / 8)));
}

export class BundleWorker {
    constructor(data, onStop) {
        this.port = 0;
        this.ports = [];
        this.started = new Set();
        this.pending = new Map();
        this.sequence = 0;
        this.closed = false;
        this.failure = null;
        this.activity = { active: 0, at: 0 };
        this.activityWaiters = new Set();
        this.controller = new AbortController();
        this.onStop = onStop;
        this.worker = new Worker(new URL('./worker.mjs', import.meta.url), {
            workerData: data,
            env: { ...process.env, NODE_PATH: data.profile },
            resourceLimits: { maxOldGenerationSizeMb: bundleHeapLimit() },
        });
        this.worker.on('message', message => {
            if (message.activity) {
                this.activity = message.activity;
                for (const wake of this.activityWaiters) wake();
                return;
            }
            const id = 'ready' in message ? 'ready' : message.id;
            const waiting = this.pending.get(id);
            if (!waiting) return;
            const error = message.error || (id === 'ready' && !message.ready ? 'The CatPawOpen server did not start' : null);
            waiting.finish(error ? new Error(error) : null, message);
        });
        this.worker.once('error', error => {
            log('CATPAW_WORKER', data.bundle, thrownText(error));
            this.end(error);
        });
        this.worker.once('exit', code => {
            log('CATPAW_WORKER_EXIT', data.bundle, code);
            this.end();
        });
        this.exited = new Promise(resolve => this.worker.once('exit', resolve));
        // The local loader allows 20 s for remote config and another 20 s for
        // the source socket. Both now execute inside this worker.
        this.ready = this.waitFor('ready', 45_000).then(message => {
            if (!Number.isInteger(message.port) || message.port <= 0) throw new Error('Invalid CatPawOpen server port');
            if (this.closed) throw this.stopped();
            this.port = message.port;
            if (!this.ports.includes(this.port)) this.ports.push(this.port);
            return this;
        });
    }
    stopped() {
        const reason = this.failure?.code === 'ERR_WORKER_OUT_OF_MEMORY' ? 'ran out of memory' : 'stopped';
        return new Error(`The source ${reason} and was closed. Try again to start it again.`);
    }
    end(error) {
        if (error) this.failure = error;
        if (this.closed) return;
        this.closed = true;
        this.controller.abort(this.stopped());
        for (const wake of this.activityWaiters) wake();
        for (const waiting of this.pending.values()) waiting.finish(this.stopped());
        this.onStop?.();
    }
    async terminate(error) {
        this.end(error);
        await this.worker.terminate();
    }
    async waitForSearchIdle(operation) {
        // A response can close before a cancelled source handler reaches its next
        // checkpoint. Keep its search slot until actual handler/HTTP work ends.
        await this.update({ activityProbe: true }).catch(() => {});
        // A CatPaw bundle can contain hundreds of source routes. One slow route
        // must not hold the completed route's slot merely because they share V8.
        const running = () => operation ? this.activity.searchOperations?.includes(operation) : this.activity.searches;
        if (this.closed || !running()) return;
        await new Promise(resolve => {
            const wake = () => {
                if (!this.closed && running()) return;
                this.activityWaiters.delete(wake); resolve();
            };
            this.activityWaiters.add(wake); wake();
        });
    }
    waitFor(id, timeout) {
        if (this.closed) return Promise.reject(this.stopped());
        return new Promise((resolve, reject) => {
            const finish = (error, value) => {
                clearTimeout(timer);
                this.pending.delete(id);
                error ? reject(error) : resolve(value);
            };
            const timer = setTimeout(() => finish(new Error('The CatPawOpen worker did not answer in time')), timeout);
            timer.unref();
            this.pending.set(id, { finish });
        });
    }
    update(message, timeout = 3000) {
        const id = ++this.sequence;
        const answer = this.waitFor(id, timeout);
        try { if (!this.closed) this.worker.postMessage({ ...message, id }); }
        catch (error) { this.pending.get(id)?.finish(error); }
        return answer;
    }
    // Race source requests against worker failure without retaining a pending
    // listener for every successful call for the rest of the worker's lifetime.
    async alive(operation) {
        if (this.closed) {
            // Callers may already have opened the HTTP request before the exit
            // event won this turn. Observe its rejection as well.
            Promise.resolve(operation).catch(() => { });
            throw this.stopped();
        }
        const signal = this.controller.signal;
        let stopped;
        const ended = new Promise((_, reject) => {
            stopped = () => reject(this.stopped());
            signal.addEventListener('abort', stopped, { once: true });
        });
        try { return await Promise.race([operation, ended]); }
        catch (error) {
            // V8 drops its sockets just before reporting worker OOM. Give the
            // error event one turn to replace a generic ECONNRESET diagnostic.
            if (!this.closed && ['ECONNREFUSED', 'ECONNRESET', 'EPIPE'].includes(error?.code))
                await new Promise(resolve => setTimeout(resolve, 100));
            throw this.closed ? this.stopped() : error;
        } finally { signal.removeEventListener('abort', stopped); }
    }
}
