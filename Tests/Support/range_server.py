#!/usr/bin/env python3
"""Tiny HTTP server for the HTTPRangeSource tests.

/media/<file>     honors Range (206 + Content-Range)
/norange/<file>   ignores Range, always 200 with the full body
/redirect/<file>  302 -> /media/<file>
/auth/<file>      needs header X-Emby-Token: secret, else 401
/slow/<file>      waits 3 s before answering
/log              JSON list of the Range headers received so far
"""
import os, sys, json, time, re
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

ROOT = sys.argv[1]
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8765
LOG = []

class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a):
        pass
    def do_GET(self):
        if self.path == '/log':
            body = json.dumps(LOG).encode()
            self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers()
            self.wfile.write(body); return
        m = re.match(r'^/(media|norange|redirect|auth|slow)/([^?]+)', self.path)
        if not m:
            self.send_error(404); return
        mode, name = m.group(1), m.group(2)
        LOG.append({'mode': mode, 'range': self.headers.get('Range'), 'ae': self.headers.get('Accept-Encoding')})
        if mode == 'redirect':
            self.send_response(302); self.send_header('Location', '/media/' + name)
            self.send_header('Content-Length', '0'); self.end_headers(); return
        if mode == 'auth' and self.headers.get('X-Emby-Token') != 'secret':
            self.send_response(401); self.send_header('Content-Length', '0'); self.end_headers(); return
        if mode == 'slow':
            time.sleep(3)
        path = os.path.join(ROOT, name)
        if not os.path.exists(path):
            self.send_error(404); return
        size = os.path.getsize(path)
        rng = self.headers.get('Range')
        try:
            if mode != 'norange' and rng and rng.startswith('bytes='):
                a, b = rng[6:].split('-')
                a = int(a); b = min(int(b) if b else size - 1, size - 1)
                if a >= size:
                    self.send_response(416); self.send_header('Content-Range', 'bytes */%d' % size)
                    self.send_header('Content-Length', '0'); self.end_headers(); return
                self.send_response(206)
                self.send_header('Content-Range', 'bytes %d-%d/%d' % (a, b, size))
                self.send_header('Content-Length', str(b - a + 1)); self.end_headers()
                with open(path, 'rb') as f:
                    f.seek(a); left = b - a + 1
                    while left > 0:
                        chunk = f.read(min(65536, left))
                        if not chunk: break
                        self.wfile.write(chunk); left -= len(chunk)
                return
            self.send_response(200); self.send_header('Content-Length', str(size)); self.end_headers()
            with open(path, 'rb') as f:
                while True:
                    chunk = f.read(65536)
                    if not chunk: break
                    self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass

ThreadingHTTPServer(('127.0.0.1', PORT), H).serve_forever()
