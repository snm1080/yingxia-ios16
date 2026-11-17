import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import tls from 'node:tls';

// The app reaches the internet through the system's HTTP proxy when one is set (Settings > Wi-Fi > Configure
// Proxy), but Node's sockets don't, so every agent's connections tunnel through it with CONNECT. A VPN-style
// proxy needs nothing: iOS routes Node's sockets through it like the app's own.
let proxy = null; // Each isolate owns its proxy and agent pools.
export function setProxy(value) {
    const port = Number(value?.port);
    proxy = value?.host && Number.isInteger(port) && port > 0 && port <= 65535
        ? { host: String(value.host), port, exceptions: Array.isArray(value.exceptions) ? value.exceptions.filter(rule => typeof rule === 'string') : [] } : null;
    return proxy;
}
http.globalAgent.keepAlive = true;
https.globalAgent.keepAlive = true;
function direct(host) {
    host = String(host || '').replace(/^\[|\]$/g, '').toLowerCase();
    if (!proxy || host === 'localhost' || host.endsWith('.local') || /^(127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|::1$|fe80:)/.test(host)) return true;
    return proxy.exceptions.some(rule => {
        rule = rule.toLowerCase();
        return rule.startsWith('*.') ? host.endsWith(rule.slice(1)) : host === rule;
    });
}
function tunnel(options, secure, callback) {
    const host = options.host || options.hostname || 'localhost';
    const port = options.port || (secure ? 443 : 80);
    const via = proxy; // Retain the endpoint if Settings changes during CONNECT.
    const socket = net.connect(via.port, via.host);
    const fail = error => { socket.destroy(); callback(error); };
    socket.once('error', fail);
    socket.once('connect', () => socket.write(`CONNECT ${host}:${port} HTTP/1.1\r\nHost: ${host}:${port}\r\n\r\n`));
    let head = Buffer.alloc(0);
    socket.on('data', function answer(chunk) {
        head = Buffer.concat([head, chunk]);
        const end = head.indexOf('\r\n\r\n');
        if (end < 0) return;
        socket.off('data', answer);
        socket.off('error', fail);
        const status = Number(head.toString('latin1', 0, end).split(' ')[1]);
        if (status !== 200) return fail(new Error(`The proxy ${via.host}:${via.port} refused ${host}:${port} (HTTP ${status})`));
        if (end + 4 < head.length) socket.unshift(head.subarray(end + 4));
        callback(null, secure ? tls.connect({ ...options, socket, servername: options.servername ?? (net.isIP(host) ? undefined : host) }) : socket);
    });
}
for (const [Agent, secure] of [[http.Agent, false], [https.Agent, true]]) {
    const connect = Agent.prototype.createConnection;
    Agent.prototype.createConnection = function (options, callback) {
        if (direct(options.host || options.hostname)) return connect.call(this, options, callback);
        tunnel(options, secure, callback);
    };
}
// Kept-alive sockets are pooled by name, so a changed proxy doesn't reuse sockets made without it.
// https.Agent's getName builds on this one.
const getName = http.Agent.prototype.getName;
http.Agent.prototype.getName = function (options = {}) {
    const name = getName.call(this, options);
    return direct(options.host || options.hostname) ? name : `${name}:via:${proxy.host}:${proxy.port}`;
};

