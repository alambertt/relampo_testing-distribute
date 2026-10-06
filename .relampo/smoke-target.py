from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json, pathlib, threading, time

lock = threading.Lock()
log = pathlib.Path('results/target-requests.txt')
log.parent.mkdir(parents=True, exist_ok=True)
log.touch()

class Target(BaseHTTPRequestHandler):
    def do_GET(self):
        if not self.path.startswith(('/A/', '/B/')):
            self.send_response(404)
            self.end_headers()
            return
        with lock:
            with log.open('a') as out:
                out.write(json.dumps({'path': self.path, 'at': time.time()}) + '\n')
        time.sleep(0.1 if self.path.startswith('/A/') else 0.05)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'ok')
    def log_message(self, *args):
        pass

ThreadingHTTPServer(('127.0.0.1', 8765), Target).serve_forever()
