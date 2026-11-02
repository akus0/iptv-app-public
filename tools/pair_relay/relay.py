#!/usr/bin/env python3
"""Optional iptv-app pairing and encrypted-transfer relay.

Pairing forms are encrypted by the browser; the key stays in the URL fragment.
The relay keeps ciphertext in memory, consumed once or expired after ten minutes.

    GET /p             -> bundled pairing form
    PUT /api/s/<id>    -> store {"iv", "ct"} once; 409 if occupied
    GET /api/s/<id>    -> consume ciphertext; 404 if missing

The transfer vault stores encrypted blobs on disk with an expiry and a hashed
write token. Keys stay with clients; the relay cannot decrypt either payload.

    PUT    /api/v/<id> -> store/replace; X-Vault-Token and X-Vault-Ttl headers
    GET    /api/v/<id> -> read ciphertext until expiry
    DELETE /api/v/<id> -> remove with the matching write token

PAIR_REQUIRE_APP=1 requires the retained X-VesperTV-App protocol marker for
app requests. This marker is not authentication; browser pairing uploads do
not need it. Logs contain aggregate counts, never request paths or bodies.

Uses only the Python standard library. Bind to loopback behind a TLS proxy.
See README.md for configuration and deployment templates.
"""
import hashlib
import hmac
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("PAIR_HOST", "127.0.0.1")
PORT = int(os.environ.get("PAIR_PORT", "8930"))
PAGE = os.environ.get("PAIR_PAGE", os.path.join(os.path.dirname(__file__), "../../assets/pair/pair.html"))
TTL = 600            # seconds a blob may wait for its TV
MAX_BODY = 8 * 1024  # an encrypted form is well under 2 KB
MAX_ITEMS = 2000     # memory cap; oldest are dropped first

ID_RE = re.compile(r"^/api/s/([A-Za-z0-9_-]{16,64})$")

VAULT_DIR = os.environ.get("PAIR_VAULT_DIR", "/var/lib/pair-relay")
VAULT_MAX_TTL = 7 * 24 * 3600          # raise for cloud sync later
VAULT_MAX_BODY = 8 * 1024 * 1024       # a gzipped setup is ~100-300 KB
VAULT_MAX_TOTAL = 2 * 1024 * 1024 * 1024  # disk cap for all blobs
VAULT_PRUNE_EVERY = 300
VAULT_ID_RE = re.compile(r"^/api/v/([A-Za-z0-9_-]{22,64})$")
TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{32,128}$")

APP_HEADER = "X-VesperTV-App"
REQUIRE_APP = os.environ.get("PAIR_REQUIRE_APP", "") == "1"
APP_REPORT_EVERY = 3600

_vault_lock = threading.Lock()
_app_lock = threading.Lock()
_app_counts = {"app": 0, "other": 0}


def _app_reporter():
    while True:
        time.sleep(APP_REPORT_EVERY)
        with _app_lock:
            app, other = _app_counts["app"], _app_counts["other"]
            _app_counts["app"] = _app_counts["other"] = 0
        if app or other:
            print(f"app calls last hour: {app} with {APP_HEADER}, {other} "
                  f"without ({'rejected' if REQUIRE_APP else 'allowed'})",
                  file=sys.stderr, flush=True)


def _vault_paths(vid):
    return (os.path.join(VAULT_DIR, vid + ".bin"),
            os.path.join(VAULT_DIR, vid + ".meta"))


def _vault_meta(vid):
    """The blob's {"exp", "tok", "size"}, or None if missing/expired."""
    blob, meta = _vault_paths(vid)
    try:
        with open(meta, "r", encoding="utf-8") as f:
            m = json.load(f)
    except (OSError, ValueError):
        return None
    if m.get("exp", 0) <= time.time():
        _vault_remove(vid)
        return None
    return m


def _vault_remove(vid):
    for p in _vault_paths(vid):
        try:
            os.remove(p)
        except OSError:
            pass


def _vault_total():
    total = 0
    try:
        for name in os.listdir(VAULT_DIR):
            if name.endswith(".bin"):
                try:
                    total += os.path.getsize(os.path.join(VAULT_DIR, name))
                except OSError:
                    pass
    except OSError:
        pass
    return total


def _vault_prune():
    now = time.time()
    with _vault_lock:
        try:
            names = os.listdir(VAULT_DIR)
        except OSError:
            return
        for name in names:
            path = os.path.join(VAULT_DIR, name)
            if name.endswith(".meta"):
                try:
                    with open(path, "r", encoding="utf-8") as f:
                        exp = json.load(f).get("exp", 0)
                except (OSError, ValueError):
                    exp = 0
                if exp <= now:
                    _vault_remove(name[:-5])
            elif name.endswith(".tmp") or (
                    name.endswith(".bin")
                    and not os.path.exists(path[:-4] + ".meta")):
                # Half-written upload or orphan blob (crash mid-write).
                try:
                    if now - os.path.getmtime(path) > 60:
                        os.remove(path)
                except OSError:
                    pass


def _vault_pruner():
    while True:
        _vault_prune()
        time.sleep(VAULT_PRUNE_EVERY)


def _token_hash(token):
    return hashlib.sha256(token.encode("ascii")).hexdigest()


def _write_atomic(path, data):
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)

_lock = threading.Lock()
_store = {}  # id -> (created, body bytes)


def _prune(now):
    for k in [k for k, (t, _) in _store.items() if now - t > TTL]:
        del _store[k]
    while len(_store) > MAX_ITEMS:
        del _store[min(_store, key=lambda k: _store[k][0])]


def _load_page():
    with open(PAGE, "rb") as f:
        return f.read()


class Handler(BaseHTTPRequestHandler):
    server_version = "pair"
    sys_version = ""

    def log_message(self, fmt, *args):  # no access log: URLs carry session ids
        pass

    def _send(self, code, body=b"", ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        if ctype.startswith("text/html"):
            self.send_header(
                "Content-Security-Policy",
                "default-src 'none'; style-src 'unsafe-inline'; "
                "script-src 'unsafe-inline'; connect-src 'self'; "
                "form-action 'none'; base-uri 'none'; frame-ancestors 'none'",
            )
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _app_ok(self):
        """Counts an app call; False (403 sent) if it lacks the app header
        while PAIR_REQUIRE_APP is on."""
        ok = bool(self.headers.get(APP_HEADER))
        with _app_lock:
            _app_counts["app" if ok else "other"] += 1
        if ok or not REQUIRE_APP:
            return True
        self._send(403)
        return False

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/p", "/p/"):
            try:
                return self._send(200, _load_page(), "text/html; charset=utf-8")
            except OSError:
                return self._send(500)
        v = VAULT_ID_RE.match(path)
        if v:
            if not self._app_ok():
                return
            return self._vault_get(v.group(1))
        m = ID_RE.match(path)
        if not m:
            return self._send(404)
        if not self._app_ok():
            return
        now = time.time()
        with _lock:
            _prune(now)
            item = _store.pop(m.group(1), None)
        if item is None:
            return self._send(404)
        return self._send(200, item[1])

    def do_PUT(self):
        path = self.path.split("?", 1)[0]
        v = VAULT_ID_RE.match(path)
        if v:
            if not self._app_ok():
                return
            return self._vault_put(v.group(1))
        m = ID_RE.match(path)
        if not m:
            return self._send(404)
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self._send(400)
        if length <= 0 or length > MAX_BODY:
            return self._send(413)
        body = self.rfile.read(length)
        try:
            data = json.loads(body)
            if not (isinstance(data, dict) and isinstance(data.get("iv"), str)
                    and isinstance(data.get("ct"), str)):
                raise ValueError
        except ValueError:
            return self._send(400)
        now = time.time()
        with _lock:
            _prune(now)
            if m.group(1) in _store:
                return self._send(409)
            _store[m.group(1)] = (now, body)
        return self._send(204)

    def do_POST(self):
        self._send(405)

    def do_DELETE(self):
        v = VAULT_ID_RE.match(self.path.split("?", 1)[0])
        if not v:
            return self._send(404)
        if not self._app_ok():
            return
        token = self.headers.get("X-Vault-Token", "")
        if not TOKEN_RE.match(token):
            return self._send(400)
        with _vault_lock:
            m = _vault_meta(v.group(1))
            if m is None:
                return self._send(404)
            if not hmac.compare_digest(m.get("tok", ""), _token_hash(token)):
                return self._send(403)
            _vault_remove(v.group(1))
        return self._send(204)

    # --------------------------------------------------------------- vault

    def _vault_get(self, vid):
        with _vault_lock:
            m = _vault_meta(vid)
            if m is None:
                return self._send(404)
            try:
                with open(_vault_paths(vid)[0], "rb") as f:
                    body = f.read()
            except OSError:
                return self._send(404)
        return self._send(200, body, "application/octet-stream")

    def _vault_put(self, vid):
        token = self.headers.get("X-Vault-Token", "")
        try:
            ttl = int(self.headers.get("X-Vault-Ttl", "0"))
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self._send(400)
        if not TOKEN_RE.match(token) or not 60 <= ttl <= VAULT_MAX_TTL:
            return self._send(400)
        if length < 29 or length > VAULT_MAX_BODY:  # version+nonce+tag
            return self._send(413 if length > VAULT_MAX_BODY else 400)
        body = self.rfile.read(length)
        if len(body) != length:
            return self._send(400)
        tok = _token_hash(token)
        blob, meta = _vault_paths(vid)
        with _vault_lock:
            m = _vault_meta(vid)
            if m is not None and not hmac.compare_digest(m.get("tok", ""), tok):
                return self._send(409)
            old = m.get("size", 0) if m else 0
            if _vault_total() - old + length > VAULT_MAX_TOTAL:
                return self._send(507)
            try:
                _write_atomic(blob, body)
                _write_atomic(meta, json.dumps(
                    {"exp": int(time.time()) + ttl, "tok": tok,
                     "size": length}).encode("utf-8"))
            except OSError:
                _vault_remove(vid)
                return self._send(500)
        return self._send(204)


def main():
    _load_page()  # fail fast if the page is missing
    os.makedirs(VAULT_DIR, exist_ok=True)
    threading.Thread(target=_vault_pruner, daemon=True).start()
    threading.Thread(target=_app_reporter, daemon=True).start()
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    srv.daemon_threads = True
    print(f"pair relay on {HOST}:{PORT}", file=sys.stderr, flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
