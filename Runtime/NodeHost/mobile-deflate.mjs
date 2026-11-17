import { Transform } from 'node:stream';
import { createInflate, createInflateRaw } from 'node:zlib';

// HTTP calls both the RFC 1950 wrapper and Bilibili's RFC 1951 raw stream
// "deflate". Inspect only its two-byte header; keep decompression streaming so
// the caller's decoded-byte limit and cancellation still bound the response.
export function createHTTPInflate() { return new HTTPInflate(); }

class HTTPInflate extends Transform {
  #prefix;
  #decoder;
  _transform(chunk, encoding, callback) {
    if (!this.#decoder) {
      const bytes = this.#prefix ? Buffer.concat([this.#prefix, chunk]) : chunk;
      if (bytes.length < 2) { this.#prefix = bytes; callback(); return; }
      this.#prefix = undefined;
      const wrapped = (bytes[0] & 15) === 8 && (bytes[0] >> 4) <= 7 && ((bytes[0] << 8) | bytes[1]) % 31 === 0;
      this.#decoder = wrapped ? createInflate() : createInflateRaw();
      this.#decoder.on('data', value => { if (!this.push(value)) this.#decoder.pause(); });
      this.#decoder.on('error', error => this.destroy(error));
      chunk = bytes;
    }
    this.#decoder.write(chunk, callback);
  }
  _read(size) { this.#decoder?.resume(); super._read(size); }
  _flush(callback) {
    if (!this.#decoder) { callback(new Error('Incomplete deflate response')); return; }
    this.#decoder.once('end', callback);
    this.#decoder.end();
  }
  _destroy(error, callback) { this.#decoder?.destroy(); callback(error); }
}
