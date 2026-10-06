from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json, os, pathlib, threading, time

lock = threading.Lock()
log = pathlib.Path('results/target-requests.txt')
log.parent.mkdir(parents=True, exist_ok=True)
log.touch()
phase = os.environ['RELAMPO_SMOKE_PHASE']
node = int(os.environ['RELAMPO_SMOKE_NODE'])

class Target(BaseHTTPRequestHandler):
    def do_GET(self):
        if not self.path.startswith('/' + phase + '/'):
            self.send_response(404)
            self.end_headers()
            return
        started = time.time()
        time.sleep(0.6 if phase == 'A' and node == 1 else 0.05)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'ok')
        with lock:
            with log.open('a') as out:
                out.write(json.dumps({'phase': phase, 'node': node, 'path': self.path,
                    'started': started, 'ended': time.time()}) + '\n')
    def log_message(self, *args):
        pass

ThreadingHTTPServer(('127.0.0.1', 8765), Target).serve_forever()
