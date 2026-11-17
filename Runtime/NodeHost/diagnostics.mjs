import { inspect } from 'node:util';

// A bundle can log circular objects, BigInts or objects with hostile getters.
// Logging from an uncaughtException listener must never throw back into Node.
export function thrownText(error) {
    try { return typeof error?.stack === 'string' ? error.stack : String(error); }
    catch { return logText(error); }
}
function logText(value) {
    if (typeof value === 'string') return value;
    try { const json = JSON.stringify(value); if (json !== undefined) return json; } catch { }
    try { return inspect(value, { customInspect: false, getters: false, depth: 3 }); }
    catch { return '[unprintable value]'; }
}
export function log(...values) {
    try { process.stderr.write(values.map(logText).join(' ') + '\n'); } catch { }
}
export function installDiagnostics() {
    process.env.NODE_ENV = 'development'; // Fastify then skips its per-request logger
    Object.assign(console, { log, info: log, warn: log, error: log, debug: log });
    // Some handlers answer twice; retain the existing CatVod compatibility.
    process.on('uncaughtException', error => log('CATPAW_UNCAUGHT', thrownText(error)));
    process.on('unhandledRejection', error => log('CATPAW_UNHANDLED', thrownText(error)));
    // A closed diagnostic pipe must not create a second uncaught exception.
    process.stderr.on('error', () => { });
}
