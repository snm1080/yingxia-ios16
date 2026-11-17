import http from 'node:http';
import net from 'node:net';
import { syncBuiltinESMExports } from 'node:module';

// A bundle can start its built-in danmaku API through a one-shot module initializer.
// iOS may later reclaim that listening handle without unloading its module. Keep only
// this worker's local HTTP server handles so an explicit host wake can reopen them at
// their original address, preserving the bundle's configured port and allowlist.
export function trackLocalHTTPListeners(excluded = () => null, activity = () => {}) {
    const createServer = http.createServer;
    const servers = new Map();
    http.createServer = function (...args) {
        const server = createServer.apply(this, args);
        server.on('request', (request, response) => {
            const search = request.headers['x-yingxia-search'] === '1';
            const operation = request.headers['x-yingxia-search-operation'];
            activity(1, search, operation);
            let finished = false;
            const end = () => {
                if (finished) return;
                finished = true; response.off('finish', end); response.off('close', end);
                activity(-1, search, operation);
            };
            response.once('finish', end); response.once('close', end);
        });
        server.on('listening', () => {
            const address = server.address();
            if (typeof address !== 'object' || !address || !Number.isInteger(address.port)
                || !['127.0.0.1', '::1', '0.0.0.0', '::'].includes(address.address)) return;
            // A WeakRef never keeps a source-disposed server alive merely for recovery.
            let entry = [...servers.values()].find(value => value.server.deref() === server);
            if (!entry) { entry = { server: new WeakRef(server) }; servers.set(entry.server, entry); }
            entry.port = address.port;
            entry.host = address.address;
        });
        return server;
    };
    syncBuiltinESMExports();

    async function reachable(server, entry) {
        return await new Promise(resolve => {
            const accepted = [];
            let connected = false, finished = false;
            const connection = incoming => {
                accepted.push(incoming.remotePort);
                if (connected && incoming.remotePort === socket.localPort) finish(true);
            };
            server.on('connection', connection);
            const socket = net.createConnection({ port: entry.port,
                host: ['::', '::1'].includes(entry.host) ? '::1' : '127.0.0.1' });
            const finish = value => {
                if (finished) return;
                finished = true; clearTimeout(timer); server.off('connection', connection);
                socket.destroy(); resolve(value);
            };
            const timer = setTimeout(() => finish(connected ? 'conflict' : false), 300);
            timer.unref();
            socket.once('connect', () => {
                connected = true;
                if (accepted.includes(socket.localPort)) finish(true);
            });
            socket.once('error', () => finish(false));
        });
    }
    return async function relistenLocal(port = null) {
        for (const [key, entry] of servers) {
            const server = entry.server.deref();
            if (!server) { servers.delete(key); continue; }
            if (server === excluded() || port !== null && entry.port !== port) continue;
            // The JS handle can still claim listening after the OS reclaims its socket.
            // Probe only on an explicit host wake or an advertised built-in danmaku request.
            if (server.listening) {
                const state = await reachable(server, entry);
                if (state === true) continue;
                if (state === 'conflict') throw new Error('The original local source port is now owned by another listener');
            }
            await new Promise((resolve, reject) => {
                const finish = error => {
                    clearTimeout(timer);
                    server.off('listening', ready); server.off('error', failed);
                    error ? reject(error) : resolve();
                };
                const ready = () => finish();
                const failed = error => finish(error);
                const timer = setTimeout(() => finish(new Error('The local source listener did not reopen in time')), 1000);
                timer.unref();
                server.once('listening', ready); server.once('error', failed);
                // Never select another port or attach to whoever now occupies this one.
                // A conflict is reported to the host, which retires only this worker.
                try {
                    if (server.listening) server.close();
                    server.listen({ port: entry.port, host: entry.host });
                }
                catch (error) { finish(error); }
            });
        }
    };
}
