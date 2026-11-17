"""Run TVBox Python spiders with the same file protocol as ScriptHost/host.mjs.

macOS runs one sandboxed process per source: `host.py --serve request.json` loads the spider, writes
`ready.json`, then reads one JSON command per stdin line and writes `responses/<id>.json`. Without
`--serve` it answers `params` once on stdout. iOS and tvOS embed the interpreter and import this module
instead: `handle(json)` answers one request for any of the app's Python sources (ApplePython.c).
Spider `localProxy` responses are served from a loopback HTTP server for playback.
"""
import inspect
import ast
import builtins
import tokenize
import types
import json
import os
import re
import sys
import threading
import time
import weakref
import select
import socket
import traceback
import http.client
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from hashlib import sha256
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from urllib.parse import parse_qsl, urljoin, urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [HERE, os.path.join(HERE, 'site-packages')]
try:
    import certifi
    os.environ.setdefault('SSL_CERT_FILE', certifi.where())
except ImportError:
    pass

import requests
import urllib3
from base import spider as base
from base.catalog import CatalogState, normalize_player, unresolved_direct_player

urllib3.disable_warnings()


def log(*values):
    print(*values, file=sys.stderr, flush=True)


def write_json(path, value):
    with open(path + '.tmp', 'w', encoding='utf-8') as stream:
        json.dump(value, stream, ensure_ascii=False)
    os.replace(path + '.tmp', path)


class RemoteFailure(Exception):
    def __init__(self, host, status, message):
        super().__init__(message)
        self.host, self.status = host, status


# The last upstream failure, so an empty spider result can explain itself. A process that serves one
# source keeps it process-wide (spiders fetch on their own threads too); an embedded interpreter
# serves many sources at once, so there each request thread keeps its own.
last_failure = None
_thread = threading.local()
_shared = True
_send = requests.Session.send
_sleep = time.sleep
_urlopen = urllib.request.OpenerDirector.open
_response_begin = http.client.HTTPResponse.begin
_executor_submit = ThreadPoolExecutor.submit


class RequestStopped(BaseException):
    """A host stop must pass through a source's usual `except Exception: retry` handlers."""
    def __init__(self, code):
        self.code = code
        super().__init__('The source took too long to respond.' if code == 'request_timeout' else 'The source request was cancelled.')


_requests_lock = threading.Lock()
_requests = {}
_cancelled_requests = {}


def current_request():
    return getattr(_thread, 'request_scope', None)


def executor_submit(executor, function, /, *args, **kwargs):
    """A source's child tasks share its deadline, bytecode checks and tracked sockets.

    Capture on submission, not worker creation: reused pools serve different requests.
    Child cleanup restores the worker without unregistering the parent's request or timer.
    """
    scope = current_request()
    if scope is None:
        return _executor_submit(executor, function, *args, **kwargs)

    def run():
        previous, previous_trace = current_request(), sys.gettrace()
        _thread.request_scope = scope
        sys.settrace(scope.trace)
        try:
            scope.check()
            result = function(*args, **kwargs)
            scope.check()
            return result
        finally:
            sys.settrace(previous_trace)
            _thread.request_scope = previous

    return _executor_submit(executor, run)


ThreadPoolExecutor.submit = executor_submit


def interrupt_body(body):
    """Shutdown before close: a buffered socket read holds a lock that close would wait on."""
    try:
        stream = body.raw._fp if isinstance(body, requests.Response) else body
        stream.fp.raw._sock.shutdown(socket.SHUT_RDWR)
    except (AttributeError, OSError):
        pass


class RequestScope:
    def __init__(self, request):
        self.id = str(request.get('request') or '')
        default = 25 if 'wd' in (request.get('params') or {}) else 140
        try:
            timeout = min(140, max(.05, float(request.get('timeoutSeconds', default))))
        except (TypeError, ValueError):
            timeout = default
        self.deadline = time.monotonic() + timeout
        self.event = threading.Event()
        self.lock = threading.Lock()
        self.code = None
        self.bodies = weakref.WeakSet()
        self.timer = threading.Timer(timeout, self.stop, args=('request_timeout',))
        self.timer.daemon = True
        folder = os.path.realpath(request.get('sourceDirectory') or os.path.dirname(request.get('script') or HERE))
        source = os.path.abspath(request.get('sourceDirectory') or os.path.dirname(request.get('script') or HERE))
        modules = os.path.realpath(os.path.join(request.get('profile') or '', 'modules'))
        self.source_folders = (folder + os.sep, source + os.sep, modules + os.sep)

    def __enter__(self):
        self.previous = current_request()
        self.previous_trace = sys.gettrace()
        _thread.request_scope = self
        if self.id:
            with _requests_lock:
                if _cancelled_requests.pop(self.id, None) is not None:
                    self.stop('request_cancelled')
                _requests[self.id] = self
        self.timer.start()
        # Trace source bytecode, not host locks or framework cleanup. Native extensions/DNS
        # still own their waits; the Swift worker keeps its slot until they actually return.
        sys.settrace(self.trace)
        return self

    def finish(self):
        sys.settrace(self.previous_trace)
        _thread.request_scope = self.previous
        self.timer.cancel()
        with _requests_lock:
            if _requests.get(self.id) is self:
                _requests.pop(self.id, None)
        if self.event.is_set():
            for body in tuple(self.bodies):
                try:
                    body.close()
                except (OSError, ValueError):
                    pass

    def __exit__(self, *_):
        self.finish()

    def detach_deadline(self):
        """Only acquiring/rewriting a proxy response is deadline-bound; movies may run for hours."""
        self.timer.cancel()
        self.deadline = float('inf')

    def trace(self, frame, event, arg):
        if frame.f_code.co_filename.startswith(self.source_folders):
            self.check()
            return self.trace
        return None

    def check(self):
        if self.event.is_set():
            raise RequestStopped(self.code)
        if time.monotonic() >= self.deadline:
            self.stop('request_timeout')
            raise RequestStopped(self.code)

    def stop(self, code):
        with self.lock:
            if self.code is not None:
                return
            self.code = code
            self.event.set()
            bodies = tuple(self.bodies)
        for body in bodies:
            interrupt_body(body)

    def track(self, body):
        with self.lock:
            self.bodies.add(body)
            stopped = self.code is not None
        if stopped:
            interrupt_body(body)
            self.check()

    def timeout(self, value=None):
        self.check()
        if self.deadline == float('inf'):
            # The whole stream is unlimited, but each later network operation
            # still needs a finite timeout: sockets cannot accept infinity.
            if isinstance(value, tuple):
                return tuple(20 if item is None else float(item) for item in value)
            if value is None or value is socket._GLOBAL_DEFAULT_TIMEOUT:
                return 20
            return value
        remaining = max(.001, self.deadline - time.monotonic())
        if isinstance(value, tuple):
            return tuple(min(float(item), remaining) if item is not None else remaining for item in value)
        if value is None or value is socket._GLOBAL_DEFAULT_TIMEOUT:
            return remaining
        try:
            return min(float(value), remaining)
        except (TypeError, ValueError):
            return urllib3.util.Timeout(total=remaining, connect=remaining, read=remaining)


def cancel_request(request_id):
    if not re.fullmatch(r'[A-Za-z0-9-]{1,80}', request_id):
        return
    with _requests_lock:
        scope = _requests.get(request_id)
        if scope is None:
            now = time.monotonic()
            for key, deadline in tuple(_cancelled_requests.items()):
                if deadline < now:
                    _cancelled_requests.pop(key, None)
            _cancelled_requests[request_id] = now + 60
            while len(_cancelled_requests) > 256:
                _cancelled_requests.pop(next(iter(_cancelled_requests)))
    if scope:
        scope.stop('request_cancelled')


def sleep(seconds):
    scope = current_request()
    if scope is None:
        return _sleep(seconds)
    if seconds < 0:
        return _sleep(seconds)
    scope.check()
    scope.event.wait(min(seconds, max(0, scope.deadline - time.monotonic())))
    scope.check()


def response_begin(response):
    scope = current_request()
    if scope:
        scope.track(response)
    return _response_begin(response)


def urlopen(opener, url, data=None, timeout=socket._GLOBAL_DEFAULT_TIMEOUT):
    scope = current_request()
    if scope:
        timeout = scope.timeout(timeout)
    try:
        response = _urlopen(opener, url, data, timeout)
    except Exception:
        if scope:
            scope.check()
        raise
    if scope:
        scope.track(response)
        scope.check()
    return response


time.sleep = sleep
http.client.HTTPResponse.begin = response_begin
urllib.request.OpenerDirector.open = urlopen


@contextmanager
def source_lock(lock, scope):
    while not lock.acquire(timeout=.05):
        scope.check()
    try:
        scope.check()
        yield
    finally:
        lock.release()


def record_failure(failure):
    global last_failure
    if _shared:
        last_failure = failure
    else:
        _thread.failure = failure


def recorded_failure():
    return last_failure if _shared else getattr(_thread, 'failure', None)


def send(session, prepared, **options):
    """Record the last upstream failure, and bound waits."""
    host = urlsplit(prepared.url).netloc
    if options.get('timeout') is None:
        options['timeout'] = 20
    scope = current_request()
    if scope:
        options['timeout'] = scope.timeout(options.get('timeout'))
    try:
        response = _send(session, prepared, **options)
    except requests.RequestException as error:
        if scope:
            scope.check()
        record_failure(RemoteFailure(host, 0, f'Network request failed: {error}'))
        log('PY_HTTP_FAILED', host, error)
        raise
    if scope:
        scope.track(response)
        scope.check()
    log('PY_HTTP', host + urlsplit(prepared.url).path, response.status_code)
    if response.status_code >= 400:
        record_failure(RemoteFailure(host, response.status_code, f'The source {host} returned HTTP {response.status_code}'))
    elif (failure := recorded_failure()) and failure.host == host:
        record_failure(None)
    return response


requests.Session.send = send


def envelope(error):
    if isinstance(error, RequestStopped):
        return {'error': str(error), 'errorCode': error.code}
    log(''.join(traceback.format_exception(error)))
    if isinstance(error, requests.RequestException) and recorded_failure():
        error = recorded_failure()
    if isinstance(error, RemoteFailure):
        return {'error': str(error), 'errorCode': 'source_http' if error.status else 'source_network', 'host': error.host, 'status': error.status}
    return {'error': f'{type(error).__name__}: {error}', 'errorCode': 'script_error'}


def load_source(name, path, importer=None):
    loader = SourceFileLoader(name, path)
    module = module_from_spec(spec_from_loader(name, loader))
    sys.modules[name] = module
    if importer is not None:
        module.__dict__['__builtins__'] = dict(vars(builtins), __import__=importer)
    loader.exec_module(module)
    return module


class SourceModules:
    """Each imported file set owns a package namespace; sibling names never leak across sources."""
    owners = {}
    owners_lock = threading.Lock()

    def __init__(self, directory):
        self.directory = os.path.realpath(directory)
        self.package = '_yingxia_' + sha256(self.directory.encode()).hexdigest()[:24]
        self.closed = False
        with self.owners_lock:
            self.owners[self.package] = self.owners.get(self.package, 0) + 1
            if self.package not in sys.modules:
                module = types.ModuleType(self.package)
                module.__path__ = [self.directory]
                sys.modules[self.package] = module

    def close(self):
        with self.owners_lock:
            if self.closed:
                return
            self.closed = True
            remaining = self.owners[self.package] - 1
            if remaining:
                self.owners[self.package] = remaining
                return
            self.owners.pop(self.package)
            for name in tuple(sys.modules):
                if name == self.package or name.startswith(self.package + '.'):
                    sys.modules.pop(name, None)

    def load(self, name):
        if not name:
            return sys.modules[self.package]
        if not all(re.fullmatch(r'\w+', part) for part in name.split('.')):
            raise ModuleNotFoundError(name)
        qualified = self.package + '.' + name
        if qualified in sys.modules:
            return sys.modules[qualified]
        parent_name, _, child = name.rpartition('.')
        parent = self.load(parent_name)
        path = os.path.join(self.directory, *name.split('.'))
        try:
            if os.path.isfile(path + '.py'):
                module = load_source(qualified, path + '.py', self.import_module)
            elif os.path.isdir(path):
                module = types.ModuleType(qualified)
                module.__path__ = [path]
                module.__package__ = qualified
                sys.modules[qualified] = module
                if os.path.isfile(os.path.join(path, '__init__.py')):
                    module = load_source(qualified, os.path.join(path, '__init__.py'), self.import_module)
            else:
                raise ModuleNotFoundError(name)
            setattr(parent, child, module)
            return module
        except BaseException:
            sys.modules.pop(qualified, None)
            raise

    def import_module(self, name, globals=None, locals=None, fromlist=(), level=0):
        target = name
        if level:
            package = (globals or {}).get('__package__', self.package)
            parent = package.split('.')[1:]
            if level > len(parent) + 1:
                raise ImportError('relative import beyond source directory')
            prefix = parent[:len(parent) + 1 - level]
            target = '.'.join(prefix + ([name] if name else []))
        first = target.split('.')[0]
        path = os.path.join(self.directory, first)
        # All relative imports, including `from . import helper`, stay inside the owned package.
        local = bool(level) or (first != 'base' and first and
                               (os.path.isfile(path + '.py') or os.path.isdir(path)))
        if local:
            module = self.load(target)
            for child in fromlist or ():
                if child != '*' and not hasattr(module, child):
                    try:
                        setattr(module, child, self.load('.'.join(part for part in (target, child) if part)))
                    except ModuleNotFoundError:
                        pass
            return module if fromlist else self.load(first)
        return builtins.__import__(name, globals, locals, fromlist, level)

    def entry(self, path):
        real = os.path.realpath(path)
        relative = os.path.relpath(real, self.directory)
        if os.path.commonpath([real, self.directory]) != self.directory:
            raise ValueError('Script is outside its imported directory')
        name = relative[:-3].replace(os.sep, '.')
        if all(re.fullmatch(r'\w+', part) for part in name.split('.')):
            return self.load(name)
        # Document names may contain spaces, brackets or emoji. Only their
        # internal module identity needs to be a Python identifier; the file
        # name and its owned directory stay unchanged.
        parent = os.path.dirname(relative).replace(os.sep, '.')
        package = self.load(parent)
        child = '_entry_' + sha256(relative.encode()).hexdigest()[:24]
        qualified = package.__name__ + '.' + child
        if qualified in sys.modules:
            return sys.modules[qualified]
        try:
            module = load_source(qualified, real, self.import_module)
            setattr(package, child, module)
            return module
        except BaseException:
            sys.modules.pop(qualified, None)
            raise


def validate_python(files):
    entries = []
    try:
        for path, name in files.items():
            with tokenize.open(path) as source:
                tree = ast.parse(source.read(), filename=name)
            if any((isinstance(n, ast.ClassDef) and n.name == 'Spider') or
                   (isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name == 'createSpider')
                   for n in tree.body):
                entries.append(name)
        return {'entries': sorted(entries)}
    except Exception as error:
        return {'error': str(error)}


_RANGE = re.compile(r'bytes=(\d*)-(\d*)$')


def is_playlist(mime, body):
    return 'mpegurl' in mime.lower() or is_dash_manifest(mime, body) or (isinstance(body, bytes) and body[:256].lstrip(b'\xef\xbb\xbf \t\r\n').startswith(b'#EXTM3U'))


def is_dash_manifest(mime, body):
    if 'dash+xml' in mime.lower():
        return True
    if not isinstance(body, bytes):
        return False
    prefix = body[:1024].lstrip(b'\xef\xbb\xbf \t\r\n')
    return re.match(rb'(?:<\?xml\b[^>]*\?>\s*)?<(?:[\w.-]+:)?MPD(?:\s|>)', prefix) is not None


class ProxyServer(ThreadingHTTPServer):
    """Media connections are concurrent, with a finite thread/socket budget per source."""
    request_queue_size = 16
    daemon_threads = True

    def __init__(self, address, handler):
        self.capacity = threading.BoundedSemaphore(8)
        self.state_lock = threading.Lock()
        self.active = 0
        self.last_activity = 0
        self.retiring = False
        super().__init__(address, handler)

    def process_request(self, request, address):
        with self.state_lock:
            accepted = not self.retiring and self.capacity.acquire(blocking=False)
            if accepted:
                self.active += 1
                self.last_activity = time.monotonic()
        if not accepted:
            try:
                request.settimeout(.25)
                request.sendall(b'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
            except OSError:
                pass
            finally:
                self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
        except BaseException:
            self.release_connection()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.release_connection()

    def release_connection(self):
        with self.state_lock:
            self.active -= 1
            self.last_activity = time.monotonic()
        self.capacity.release()

    def in_use(self):
        with self.state_lock:
            return self.active > 0 or time.monotonic() - self.last_activity < 30

    def claim_idle(self):
        with self.state_lock:
            if self.active > 0 or time.monotonic() - self.last_activity < 30:
                return False
            self.retiring = True
            return True


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    session = None  # set on each source's subclass

    def do_GET(self):
        self.answer(True)

    def do_HEAD(self):
        self.answer(False)

    def answer(self, include_body):
        session = self.session
        body = None
        sent = False
        finished = threading.Event()
        cancelled = threading.Event()
        scope = RequestScope(dict(getattr(session, 'request', {}), timeoutSeconds=30))
        scope.id = ''  # proxy connections are cancelled by their own playback socket
        scope.__enter__()
        monitor = None

        def disconnected():
            while not finished.wait(.05):
                try:
                    readable, _, _ = select.select([self.connection], [], [], .05)
                    if readable and not self.connection.recv(1, socket.MSG_PEEK):
                        raise ConnectionResetError('The playback connection was closed')
                except OSError:
                    cancelled.set()
                    scope.stop('request_cancelled')
                    # Media writes wait for the decoder's backpressure without a
                    # deadline. Closing the client must still release that write.
                    try:
                        self.connection.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                    self.close_body(body, interrupt=True, close=False)
                    return

        try:
            monitor = threading.Thread(target=disconnected, daemon=True, name='python-proxy-cancel')
            monitor.start()
            with open(os.path.join(session.cache, 'proxy-active'), 'w'):
                pass
            # Only immutable, small in-memory responses are shared. A media stream
            # never holds the source cache lock or waits for the entire movie.
            request_headers = dict(self.headers)
            cache_key = (self.path, tuple(sorted((key.lower(), value) for key, value in request_headers.items()
                if key.lower() not in ('range', 'connection', 'host'))))
            with session.cache_lock:
                cached_path, response = session.cached_response
            if cached_path != cache_key:
                response = session.proxy_response(self.path, request_headers)
                response_headers = {str(key).lower(): str(value) for key, value in response[2].items()}
                cache_control = response_headers.get('cache-control', '').lower()
                if (response[0] == 200 and isinstance(response[3], bytes) and len(response[3]) <= 1024 * 1024
                        and not is_playlist(response[1], response[3]) and 'content-range' not in response_headers
                        and not re.search(r'(?:^|,)\s*(?:no-cache|no-store)\b', cache_control)):
                    with session.cache_lock:
                        session.cached_response = (cache_key, response)
            status, mime, headers, body = response
            scope.check()
            scope.detach_deadline()
            headers = {str(key).lower(): str(value) for key, value in headers.items()
                if re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", str(key)) and not re.search(r'[\r\n]', str(value))}
            if isinstance(body, bytes):
                headers['content-length'] = str(len(body))
                if status == 200 and 'content-range' not in headers:
                    headers['accept-ranges'] = 'bytes'
                    match = _RANGE.fullmatch(self.headers.get('Range', '').strip())
                    if match and (match.group(1) or match.group(2)):
                        total = len(body)
                        if match.group(1):
                            first = int(match.group(1))
                            last = min(int(match.group(2)), total - 1) if match.group(2) else total - 1
                        else:
                            first, last = max(0, total - int(match.group(2))), total - 1
                        if first >= total or first > last:
                            status, body = 416, b''
                            headers['content-range'] = f'bytes */{total}'
                        else:
                            status, body = 206, body[first:last + 1]
                            headers['content-range'] = f'bytes {first}-{last}/{total}'
                        headers['content-length'] = str(len(body))
            length = headers.get('content-length')
            length = int(length) if length and re.fullmatch(r'\d+', length) else None
            # For an unbounded generator, EOF is framed by closing this one
            # connection; arbitrary binary chunks are never joined in memory.
            self.close_connection = True
            self.connection.settimeout(20)
            self.send_response(status)
            excluded = {'content-type', 'content-length', 'transfer-encoding', 'connection', 'keep-alive', 'proxy-connection', 'trailer', 'upgrade'}
            for key, value in headers.items():
                if key not in excluded:
                    self.send_header(key, value)
            self.send_header('Content-Type', mime)
            if length is not None:
                self.send_header('Content-Length', str(length))
            self.send_header('Connection', 'close')
            self.end_headers()
            sent = True
            if not include_body:
                return

            # DASH can leave a companion audio socket unread while consuming
            # buffered video, or the user can pause for any length of time.
            # A 20-second send deadline truncates valid media and becomes EOF.
            # The disconnect monitor, rather than elapsed playback time, owns
            # cancellation of this bounded-chunk write.
            self.connection.settimeout(None)
            delivered = 0
            for chunk in self.chunks(body):
                if cancelled.is_set():
                    break
                if length is not None:
                    chunk = chunk[:max(0, length - delivered)]
                if chunk:
                    self.wfile.write(chunk)
                    delivered += len(chunk)
                if length is not None and delivered >= length:
                    break
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, socket.timeout):
            cancelled.set()
        except (Exception, RequestStopped, SystemExit) as error:
            if isinstance(error, RequestStopped) and error.code == 'request_cancelled':
                cancelled.set()
            if not cancelled.is_set():
                log('PY_PROXY_FAILED', ''.join(traceback.format_exception(error)))
            if not sent:
                self.close_connection = True
                data = str(error).encode()
                try:
                    self.send_response(502)
                    self.send_header('Content-Type', 'text/plain')
                    self.send_header('Content-Length', str(len(data)))
                    self.send_header('Connection', 'close')
                    self.end_headers()
                    if include_body:
                        self.wfile.write(data)
                except OSError:
                    pass
        finally:
            finished.set()
            if monitor:
                monitor.join(.15)
            scope.finish()
            self.close_body(body, interrupt=cancelled.is_set())

    @staticmethod
    def chunks(body):
        size = 64 * 1024
        if isinstance(body, bytes):
            iterator = (memoryview(body)[offset:offset + size] for offset in range(0, len(body), size))
        elif isinstance(body, requests.Response):
            # Keep Content-Encoding and length consistent with the actual wire
            # bytes; iter_content() otherwise transparently decompresses them.
            iterator = body.raw.stream(size, decode_content=False)
        elif hasattr(body, 'read'):
            def reads():
                while True:
                    chunk = body.read(size)
                    if not chunk:
                        return
                    yield chunk
            iterator = reads()
        else:
            iterator = iter(body)
        for chunk in iterator:
            scope = current_request()
            if scope:
                scope.check()
            if chunk is None:
                continue
            if isinstance(chunk, str):
                chunk = chunk.encode('utf-8')
            elif not isinstance(chunk, (bytes, bytearray, memoryview)):
                raise TypeError('Python proxy chunks must contain bytes or text')
            for offset in range(0, len(chunk), size):
                yield chunk[offset:offset + size]

    @staticmethod
    def close_body(body, interrupt=False, close=True):
        if body is None or isinstance(body, bytes):
            return
        if interrupt and isinstance(body, requests.Response):
            # A concurrent buffered socket read can hold the file object's lock.
            # Shutdown its underlying socket before close to interrupt that read.
            try:
                body.raw._fp.fp.raw._sock.shutdown(socket.SHUT_RDWR)
            except (AttributeError, OSError):
                pass
        if not close:
            return
        try:
            close = getattr(body, 'close', None)
            if callable(close):
                close()
        except (OSError, ValueError):
            pass  # A generator currently executing observes cancellation on its next yield.

    def log_message(self, format, *args):
        pass


def accepts(method, count):
    try:
        parameters = inspect.signature(method).parameters.values()
    except (TypeError, ValueError):
        return True
    if any(item.kind == item.VAR_POSITIONAL for item in parameters):
        return True
    return len([item for item in parameters if item.kind in (item.POSITIONAL_ONLY, item.POSITIONAL_OR_KEYWORD)]) >= count


def invoke(method, args):
    """Legacy spiders omit trailing optional host arguments, including init()."""
    while args and not accepts(method, len(args)):
        args = args[:-1]
    return method(*args)


def parsed(value):
    if isinstance(value, (bytes, bytearray)):
        value = value.decode('utf-8')
    if isinstance(value, str):
        return json.loads(value) if value.strip() else {}
    return value or {}


class Session:
    """One source's spider, its profile and its loopback media proxy."""

    def __init__(self, request, process_wide=False):
        self.request = request
        self.closed = False
        self.cache = request['cache']
        self.profile = request.get('profile') or os.path.join(self.cache, 'profile')
        os.makedirs(self.profile, exist_ok=True)
        os.makedirs(os.path.join(self.cache, 'responses'), exist_ok=True)
        self.cached_response = (None, None)  # (path, response): players read one proxied file in many ranges
        self.cache_lock = threading.Lock()
        self.catalog = CatalogState()
        self.playback_until = 0
        self.playback_owner = False
        self.runtime = base._Runtime()
        self.runtime.cache_file = os.path.join(self.profile, 'cache.json')
        self.runtime.load_module = self.load_dependency
        if process_wide:
            base._runtime = self.runtime  # also for spiders the host never sees created
        self.server = None
        self.runtime.proxy_url = self.start_proxy()
        self.modules = SourceModules(request['sourceDirectory']) if request.get('sourceDirectory') else None
        try:
            self.spider = self.initialize()
        except BaseException:
            # Import, configuration and network failures must not leave a
            # listening proxy/thread behind on every retry.
            self.server.shutdown()
            self.server.server_close()
            self.server = None
            if self.modules:
                self.modules.close()
            raise

    def load_dependency(self, name):
        """`Spider.loadModule(name)`: a sibling `<name>.py` of the spider, cached in the profile."""
        if self.modules:
            return self.modules.load(name)
        if name in sys.modules:
            return sys.modules[name]
        if not re.fullmatch(r'[\w.-]{1,80}', name):
            raise ValueError('Invalid module name: ' + name)
        folder = os.path.join(self.profile, 'modules')
        os.makedirs(folder, exist_ok=True)
        address = urljoin(self.request['api'], name + '.py')
        path = os.path.join(folder, sha256(address.encode()).hexdigest() + '.py')
        if not os.path.exists(path):
            response = requests.get(address, headers={'User-Agent': 'Mozilla/5.0'}, timeout=20)
            response.raise_for_status()
            with open(path, 'wb') as stream:
                stream.write(response.content)
        return load_source(name, path)

    def start_proxy(self):
        self.server = ProxyServer(('127.0.0.1', 0), type('SourceProxyHandler', (ProxyHandler,), {'session': self}))
        threading.Thread(target=self.server.serve_forever, kwargs={'poll_interval': .1}, daemon=True).start()
        # Not `/proxy?`: the app treats that path as an unsupported plugin proxy and never loads it.
        return f'http://127.0.0.1:{self.server.server_address[1]}/py-proxy?do=py'

    def proxy_address(self, address):
        """Bind TVBox's legacy proxy placeholders to this source without unwrapping its target.

        Some spiders override getProxyUrl with Android's fixed port, and others return proxy://.
        Keep their encoded query intact: localProxy owns authentication, decryption and HLS edits.
        """
        if not isinstance(address, str):
            return address
        if address.lower().startswith('proxy://'):
            query = address[len('proxy://'):].lstrip('?')
        else:
            match = re.match(r'^http://(?:127\.0\.0\.1|localhost|\[::1\])(?::(-1|\d{1,5}))?/proxy(?:\?|$)', address, re.I)
            if not match or (match.group(1) is not None and int(match.group(1)) > 65535):
                return address
            query = address[match.end():]
        return self.runtime.proxy_url.split('?', 1)[0] + '?' + (query or 'do=py')

    def proxy_values(self, value):
        if isinstance(value, str):
            return self.proxy_address(value)
        if isinstance(value, dict):
            return {key: self.proxy_values(item) for key, item in value.items()}
        if isinstance(value, (list, tuple)):
            return [self.proxy_values(item) for item in value]
        return value

    def proxy_playlist(self, body):
        try:
            text = body.decode('utf-8')
        except UnicodeDecodeError:
            return body
        lines = []
        for line in text.splitlines(keepends=True):
            if line.lstrip().startswith('#'):
                line = re.sub(r'\bURI=("|\')([^"\']+)(\1)',
                    lambda match: 'URI=' + match.group(1) + self.proxy_address(match.group(2)) + match.group(1), line)
            elif line.strip():
                address = line.strip()
                line = line.replace(address, self.proxy_address(address), 1)
            lines.append(line)
        return ''.join(lines).encode('utf-8')

    def proxy_dash_manifest(self, body):
        """Bind MPD child requests to this session, preserving DASH templates and XML escapes.

        SABR sources use Android's port in SegmentTemplate attributes and BaseURL text.
        Keep the document intact rather than serializing XML: signed queries, $Number$
        formatting, namespaces and SegmentTimeline coordinates belong to the source.
        """
        try:
            text = body.decode('utf-8')
        except UnicodeDecodeError:
            return body
        text = re.sub(r'(\b(?:initialization|media|sourceURL|index)\s*=\s*)(["\'])([^"\']*)(\2)',
            lambda match: match.group(1) + match.group(2) + self.proxy_address(match.group(3)) + match.group(4), text)
        text = re.sub(r'(<(?:[\w.-]+:)?BaseURL\b[^>]*>)(\s*)([^<]*?)(\s*)(</(?:[\w.-]+:)?BaseURL\s*>)',
            lambda match: match.group(1) + match.group(2) + self.proxy_address(match.group(3)) + match.group(4) + match.group(5), text)
        return text.encode('utf-8')

    def proxy_in_use(self):
        return self.playback_owner or time.monotonic() < self.playback_until or (self.server is not None and self.server.in_use())

    def initialize(self):
        request = self.request
        module = self.modules.entry(request['script']) if self.modules else load_source('tvbox_spider_' + sha256(request['api'].encode()).hexdigest()[:16], request['script'])
        factory = getattr(module, 'createSpider', None)
        if not callable(factory):
            factory = getattr(module, 'Spider', None)
        if not callable(factory):
            raise RuntimeError('The script defines no Spider class or createSpider()')
        instance = factory()
        if instance is None or inspect.isclass(instance):
            raise RuntimeError('The spider entry must return a content instance')
        instance._tvbox_runtime = self.runtime
        setup = getattr(instance, '_host_setup', None)
        if callable(setup):
            invoke(setup, [self.runtime.proxy_url])
        extension = request.get('ext') or ''
        if not extension:
            extension = dict(parse_qsl(urlsplit(request['api']).query)).get('extend', '')
        instance.extend = extension
        dependence = getattr(instance, 'getDependence', None)
        for name in (dependence() if callable(dependence) else []) or []:
            self.load_dependency(str(name))
        initialize = getattr(instance, 'init', None)
        if callable(initialize):
            invoke(initialize, [extension])
        return instance

    def proxy_response(self, path, request_headers=None):
        """Call the spider's localProxy and normalize its [status, mime, body, headers?, base64?] result."""
        params = dict(parse_qsl(urlsplit(path).query, keep_blank_values=True))
        params['headers'] = dict(request_headers or {})
        incoming_range = next((value for key, value in params['headers'].items() if key.lower() == 'range'), None)
        if incoming_range:
            params['range'] = params['Range'] = incoming_range
        result = list(self.spider.localProxy(params) or [])
        status = int(result[0]) if result else 404
        mime = str(result[1]) if len(result) > 1 and result[1] else 'application/octet-stream'
        body = result[2] if len(result) > 2 else b''
        headers = result[3] if len(result) > 3 and isinstance(result[3], dict) else {}
        if len(result) > 4 and result[4] == 1 and isinstance(body, str):
            import base64
            body = base64.b64decode(body.split('base64,', 1)[-1])
        if isinstance(body, requests.Response):
            fields = {str(key).lower(): value for key, value in body.headers.items()}
            fields.update({str(key).lower(): value for key, value in headers.items()})
            headers = fields
            if status == 200 and body.status_code == 206:
                status = 206
            # A spider may already have eagerly read its response. Reuse those
            # bytes without asking .content to fetch a second complete body.
            if body._content_consumed and isinstance(body._content, bytes):
                data = body._content
                body.close()
                body = data
                headers.pop('content-encoding', None)
                headers['content-length'] = str(len(data))
        elif body is None:
            body = b''
        elif isinstance(body, str):
            body = body.encode('utf-8')
        elif isinstance(body, bytearray):
            body = bytes(body)
        if not isinstance(body, bytes) and is_playlist(mime, body):
            stream = body
            try:
                pieces, length = [], 0
                chunks = stream.iter_content(64 * 1024) if isinstance(stream, requests.Response) else ProxyHandler.chunks(stream)
                for chunk in chunks:
                    length += len(chunk)
                    if length > 2 * 1024 * 1024:
                        raise ValueError('The Python media playlist exceeds the 2 MiB limit')
                    pieces.append(chunk)
                body = b''.join(pieces)
                headers = {key: value for key, value in headers.items() if str(key).lower() not in ('content-length', 'content-encoding')}
            finally:
                ProxyHandler.close_body(stream)
        if isinstance(body, bytes) and is_playlist(mime, body):
            if len(body) > 2 * 1024 * 1024:
                raise ValueError('The Python media playlist exceeds the 2 MiB limit')
            rewritten = self.proxy_dash_manifest(body) if is_dash_manifest(mime, body) else self.proxy_playlist(body)
            if rewritten != body:
                body = rewritten
                headers = {key: value for key, value in headers.items()
                    if str(key).lower() not in ('content-length', 'etag', 'content-md5', 'content-encoding')}
        return status, mime, headers, body

    def call(self, params):
        spider = self.spider
        record_failure(None)
        if 'play' in params:
            flag = params.get('flag') or ''
            result = normalize_player(parsed(spider.playerContent(flag, params['play'], [])))
            if unresolved_direct_player(result):
                for candidate, address in self.catalog.alternatives(flag, params['play']):
                    scope = current_request()
                    if scope:
                        scope.check()
                    try:
                        alternate = normalize_player(parsed(spider.playerContent(candidate, address, [])))
                    except Exception:
                        continue
                    if isinstance(alternate, dict) and alternate.get('url') and not unresolved_direct_player(alternate):
                        result = alternate
                        break
                else:
                    result = dict(result, url='', msg='当前线路未返回可播放地址，请选择其他线路。')
        elif 'ids' in params:
            result = spider.detailContent([params['ids']])
        elif 'wd' in params:
            page = params.get('pg') or '1'
            paged = getattr(spider, 'searchContentPage', None)
            # The host base delegates with three arguments; a legacy two-argument override
            # needs direct invocation. Explicit source searchContentPage always wins.
            method = paged if callable(paged) and getattr(paged, '__func__', None) is not base.Spider.searchContentPage else spider.searchContent
            result = invoke(method, [params['wd'], False, page])
        elif 't' in params:
            result = spider.categoryContent(params['t'], params.get('pg') or '1', True, json.loads(params.get('filters') or '{}'))
        else:
            result = parsed(invoke(spider.homeContent, [True]))
            if not result.get('list'):
                videos = parsed(spider.homeVideoContent())
                if videos.get('list'):
                    result['list'] = videos['list']
        if result is None or result == '' or result == {}:
            if recorded_failure():
                raise recorded_failure()
            result = {}
        if isinstance(result, str):
            result = parsed(result)
        if 'play' not in params:
            result = self.catalog.normalize(result, detail='ids' in params)
        normalized = self.proxy_values(result)
        if 'play' in params and self.runtime.proxy_url.split('?', 1)[0] in json.dumps(normalized, ensure_ascii=False):
            self.playback_until = time.monotonic() + 45
        return {'result': json.dumps(normalized, ensure_ascii=False)}

    def close(self):
        if self.closed:
            return
        self.closed = True
        try:
            self.spider.destroy()
        except (Exception, SystemExit, RequestStopped) as error:
            log('PY_DESTROY_FAILED', error)
        if self.server:
            self.server.shutdown()
            self.server.server_close()
            self.server = None
        if self.modules:
            self.modules.close()
        else:
            name = 'tvbox_spider_' + sha256(self.request['api'].encode()).hexdigest()[:16]
            sys.modules.pop(name, None)
        self.cached_response = (None, None)
        self.spider = None


class _Slot:
    def __init__(self):
        self.lock = threading.Lock()  # a spider answers one request at a time
        self.session = None
        self.used = 0
        self.users = 0


_slots = {}
_slots_lock = threading.Lock()
_uses = 0
MAX_SESSIONS = 8
MAX_SESSION_SLOTS = 16  # temporary overlap of requests and proxies must also stay finite


def playback_pin(address, pinned):
    """One current player owns its Python source until switch/stop, including an indefinite pause.

    Calls only inspect existing sessions. A stale release matches its old URL and cannot clear
    the new player's source; invalid URLs never clear a valid current owner.
    """
    if not isinstance(address, str) or not isinstance(pinned, bool):
        return False
    try:
        url = urlsplit(address)
        if url.scheme != 'http' or url.hostname not in ('127.0.0.1', 'localhost', '::1') or url.username is not None or url.password is not None or url.path != '/py-proxy':
            return False
        port = url.port
    except ValueError:
        return False
    with _slots_lock:
        session = next((slot.session for slot in _slots.values() if slot.session and slot.session.server and slot.session.server.server_port == port), None)
        if session is None:
            return False
        if pinned:
            for slot in _slots.values():
                if slot.session:
                    slot.session.playback_owner = slot.session is session
        else:
            session.playback_owner = False
            session.playback_until = 0
    return True


def handle(text):
    """One request from the app (iOS and tvOS): `session` names the source's spider, opened on first use
    from `script`, `cache`, `profile`, `api`, `key` and `ext`, and `params` is the TVBox call. Answers like
    `responses/<id>.json`. Requests for different sources run side by side."""
    global _shared, _uses
    _shared = False
    try:
        request = json.loads(text)
        if request.get('validatePython') is not None:
            return json.dumps(validate_python(request['validatePython']), ensure_ascii=False)
        if request.get('command'):
            if request['command'] == 'cancel':
                cancel_request(str(request.get('request') or ''))
            elif request['command'] == 'playbackPin':
                return json.dumps({'pinned': playback_pin(request.get('url'), request.get('pinned'))})
            return '{}'
        with RequestScope(request) as scope:
            scope.check()
            key = str(request['session'])
            with _slots_lock:
                _uses += 1
                retired = _retire(keep=_slots.get(key))
                full = key not in _slots and len(_slots) >= MAX_SESSION_SLOTS
                if not full:
                    slot = _slots.get(key) or _slots.setdefault(key, _Slot())
                    slot.used = _uses
                    slot.users += 1
                    retired.extend(_retire(keep=slot))
            if full:
                for session in retired:
                    session.close()
                raise RuntimeError('The Python runtime is busy. Wait for the current sources.')
            try:
                for session in retired:
                    session.close()
                with source_lock(slot.lock, scope):
                    if slot.session is None:
                        slot.session = Session(request)
                    response = slot.session.call(request.get('params') or {})
                    scope.check()
            finally:
                with _slots_lock:
                    slot.users -= 1
    # SystemExit too: a spider's sys.exit() or exit() must not reach ApplePython.c, whose PyErr_Print
    # exits the whole app on it, with no crash report (issue #187).
    except (Exception, SystemExit, RequestStopped) as error:
        response = envelope(error)
    return json.dumps(response, ensure_ascii=False)


def _retire(keep):
    """Closes the least recently used idle sources past MAX_SESSIONS. Call with `_slots_lock` held."""
    retired = []
    for key, slot in sorted(_slots.items(), key=lambda item: item[1].used):
        if len(_slots) <= MAX_SESSIONS:
            break
        if slot is keep or slot.users or (slot.session and slot.session.proxy_in_use()) or not slot.lock.acquire(blocking=False):
            continue
        try:
            # The server admits new connections under the same lock: after this claim no
            # new localProxy can race the module/server teardown outside _slots_lock.
            if slot.session and slot.session.server and not slot.session.server.claim_idle():
                continue
            del _slots[key]
            if slot.session:
                retired.append(slot.session)
                slot.session = None
        finally:
            slot.lock.release()
    return retired


def main(arguments):
    serving = arguments[:1] == ['--serve']
    with open(arguments[1 if serving else 0], encoding='utf-8') as stream:
        request = json.load(stream)
    cache = request['cache']
    try:
        os.makedirs(cache, exist_ok=True)
        os.chdir(cache)
        session = Session(request, process_wide=True)
        if serving:
            write_json(os.path.join(cache, 'ready.json'), {'ready': True})
            for line in sys.stdin:
                if not line.strip():
                    continue
                command = json.loads(line)
                if not re.fullmatch(r'[A-Za-z0-9-]{1,80}', str(command.get('id'))):
                    raise ValueError('Invalid request identifier')
                try:
                    response = session.call(command.get('params') or {})
                except Exception as error:
                    response = envelope(error)
                write_json(os.path.join(cache, 'responses', command['id'] + '.json'), response)
        else:
            print(json.dumps(session.call(request.get('params') or {}), ensure_ascii=False), flush=True)
        return 0
    except Exception as error:
        response = envelope(error)
        if serving:
            write_json(os.path.join(cache, 'ready.json'), response)
        else:
            print(json.dumps(response, ensure_ascii=False), flush=True)
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
