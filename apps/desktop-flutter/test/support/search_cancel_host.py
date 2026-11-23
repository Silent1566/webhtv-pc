"""Controlled child: records real IPC frames and deliberately replies after cancel."""
import json
import sys
import threading
import urllib.request

sys.dont_write_bytecode = True

_base = sys.argv[1] if __name__ == "__main__" else None
_lock = threading.Lock()


def _http(base, path, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    with urllib.request.urlopen(base + path, data=data, timeout=15) as response:
        return json.loads(response.read())


def _send(request_id, result):
    body = json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}).encode()
    with _lock:
        sys.stdout.buffer.write(("Content-Length: %d\r\n\r\n" % len(body)).encode() + body)
        sys.stdout.buffer.flush()


def _dispatch(frame):
    request_id = frame.get("id")
    method = frame["method"]
    if request_id is None:
        return
    if method == "initialize":
        if "--gate-init" in sys.argv:
            _http(_base, "/gate/initialize")
        result = {"abi": "webhtv-ipc-v1", "capabilities": ["home", "category", "detail", "search", "play"]}
    elif method in ("shutdown", "destroy", "$/heartbeat"):
        result = {}
    else:
        result = _http(_base, "/gate/" + request_id)
    _send(request_id, result)
    _http(_base, "/sent", {"id": request_id})


def _run():
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return
        length = int(line.decode().split(":", 1)[1])
        while sys.stdin.buffer.readline().strip():
            pass
        frame = json.loads(sys.stdin.buffer.read(length))
        _http(_base, "/frame", frame)
        threading.Thread(target=_dispatch, args=(frame,), daemon=True).start()


# Imported by the actual Python host to exercise its cancellation implementation.
class Spider:
    def init(self, extend):
        self.base = json.loads(extend)["base"]

    def capabilities(self):
        return ["home", "category", "detail", "search", "play"]

    def search(self, params, context):
        _http(self.base, "/frame", {"id": context.request_id, "method": "search", "params": params})
        result = _http(self.base, "/gate/" + context.request_id)
        _http(self.base, "/observed", {"id": context.request_id, "cancelled": context.cancelled})
        return result

    def home(self, params, context):
        return {"list": []}

    def destroy(self):
        pass


if __name__ == "__main__":
    _run()
