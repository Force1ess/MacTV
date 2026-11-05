"""Loopback-only generated-media fixture; never reads a URL-derived filesystem path."""
import argparse
import json
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--file", required=True)
parser.add_argument("--split-root")
args = parser.parse_args()
media = Path(args.file).resolve(strict=True)
assert media.is_file()
split_root = Path(args.split_root).resolve(strict=True) if args.split_root else None
split_files = {} if split_root is None else {
    "/mtv-fixture/split-video.mp4": (split_root / "video.mp4", "video/mp4"),
    "/mtv-fixture/split-audio.m4a": (split_root / "audio.mp4", "audio/mp4"),
    "/mtv-fixture/short-audio.m4a": (split_root / "short-audio.mp4", "audio/mp4")}
lock = threading.Lock()
state = {"requests": [], "mediaRequests": 0, "foreignRequests": 0,
         "missingHeaders": 0, "cookieRequests": 0, "authorizationRequests": 0, "versionRequests": 0,
         "minimalHeaderResponses": 0}
state["weakClockResponses"] = 0
state["poolClientPorts"] = []
state["slowTailStarted"] = 0
state["slowTailCompleted"] = 0
stop = threading.Event()
changed_counts = {}
clock_counts = {}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            # Playback cancellation may close an idle keep-alive connection.
            pass

    def log_message(self, *_):
        pass

    def respond(self, code, body=b"", headers=None, keep_alive=False):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "keep-alive" if keep_alive else "close")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.close_connection = not keep_alive
        try:
            if self.path.startswith("/mtv-fixture/truncated.mp4"):
                self.wfile.write(body[:max(1, len(body) // 2)])
                self.wfile.flush()
            elif self.path.startswith("/mtv-fixture/slow-tail.mp4") and len(body) > 131072:
                with lock:
                    state["slowTailStarted"] += 1
                self.wfile.write(body[:65536])
                self.wfile.flush()
                time.sleep(3)
                self.wfile.write(body[65536:])
                self.wfile.flush()
                with lock:
                    state["slowTailCompleted"] += 1
            elif self.path.startswith("/mtv-fixture/split-video.mp4"):
                for offset in range(0, len(body), 65536):
                    self.wfile.write(body[offset:offset + 65536])
                    self.wfile.flush()
                    time.sleep(0.02)
            else:
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        if self.path == "/shutdown":
            self.respond(200, b"stopped")
            stop.set()
        else:
            self.respond(404)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if self.path == "/stats":
            with lock:
                body = json.dumps(state).encode()
            self.respond(200, body, {"Content-Type": "application/json"})
            return
        with lock:
            if self.server.foreign:
                state["foreignRequests"] += 1
            state["mediaRequests"] += 1
            if self.headers.get("Cookie"):
                state["cookieRequests"] += 1
            if self.headers.get("Authorization"):
                state["authorizationRequests"] += 1
            headers_ok = (self.headers.get("Referer") == "https://fixture.invalid/"
                          and self.headers.get("User-Agent") == "MTV-HeaderFixture/1")
            if not headers_ok:
                state["missingHeaders"] += 1
            if len(state["requests"]) < 1000:
                state["requests"].append({"path": self.path, "range": self.headers.get("Range"),
                                          "headersOK": headers_ok})
        if not headers_ok:
            self.respond(403)
            return
        if path == "/mtv-fixture/redirect.mp4":
            self.respond(302, headers={"Location": "/mtv-fixture/movie.mp4",
                                      "Set-Cookie": "mtv_fixture=ignore; Path=/"})
            return
        if path == "/mtv-fixture/escape.mp4":
            self.respond(302, headers={"Location": f"http://127.0.0.1:{foreign.server_port}/mtv-fixture/movie.mp4"})
            return
        if path not in ["/mtv-fixture/movie.mp4", "/mtv-fixture/pool.mp4", "/mtv-fixture/bad-range.mp4", "/mtv-fixture/slow.mp4", "/mtv-fixture/changed.mp4", "/mtv-fixture/minimal.mp4", "/mtv-fixture/clock.mp4", "/mtv-fixture/slow-tail.mp4", "/mtv-fixture/truncated.mp4"] and path not in split_files:
            self.respond(404)
            return
        if path == "/mtv-fixture/slow.mp4":
            time.sleep(8)
        match = re.fullmatch(r"bytes=(\d+)-(\d+)", self.headers.get("Range", ""))
        if not match:
            self.respond(400)
            return
        start, end = map(int, match.groups())
        selected, mime = split_files.get(path, (media, "video/mp4"))
        size = selected.stat().st_size
        end = min(end, size - 1)
        if start > end or end - start + 1 > 1048576:
            self.respond(416)
            return
        with selected.open("rb") as handle:
            handle.seek(start)
            data = handle.read(end - start + 1)
        reported_start = start + 1 if path == "/mtv-fixture/bad-range.mp4" else start
        etag = '"mtv-generated-v1"'
        if path == "/mtv-fixture/changed.mp4":
            with lock:
                state["versionRequests"] += 1
                changed_counts[self.path] = changed_counts.get(self.path, 0) + 1
                etag = '"version-1"' if changed_counts[self.path] == 1 else '"version-2"'
        headers = {"Content-Type": mime, "Accept-Ranges": "bytes",
                   "Content-Range": f"bytes {reported_start}-{end}/{size}", "ETag": etag,
                   "Set-Cookie": "mtv_fixture=ignore; Path=/"}
        if path == "/mtv-fixture/minimal.mp4" and self.headers.get("If-Range"):
            headers.pop("Content-Type")
            headers.pop("ETag")
            with lock:
                state["minimalHeaderResponses"] += 1
        if path == "/mtv-fixture/clock.mp4":
            headers.pop("ETag")
            with lock:
                clock_counts[self.path] = clock_counts.get(self.path, 0) + 1
                headers["Last-Modified"] = "Wed, 28 Oct 2026 22:52:18 GMT" if clock_counts[self.path] == 1 else self.date_time_string()
                state["weakClockResponses"] += 1
        if path == "/mtv-fixture/pool.mp4":
            with lock:
                state["poolClientPorts"].append(self.client_address[1])
        self.respond(206, data, headers, keep_alive=path == "/mtv-fixture/pool.mp4")


main = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
foreign = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
main.foreign, foreign.foreign = False, True
for server in [main, foreign]:
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
print(json.dumps({"port": main.server_port, "foreignPort": foreign.server_port}), flush=True)
stop.wait()
for server in [main, foreign]:
    server.shutdown()
    server.server_close()
