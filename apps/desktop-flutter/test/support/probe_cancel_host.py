"""Test-only IPC peer: holds probes, records cancellation, sends late errors."""
import json
import sys
import threading
import urllib.request

sys.dont_write_bytecode = True
_output_lock = threading.Lock()


def fetch(base, path, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    with urllib.request.urlopen(base + path, data=data, timeout=15) as response:
        return json.loads(response.read())


def answer(base, frame):
    request_id = frame.get("id")
    if request_id is None:
        return
    method = frame["method"]
    if method == "initialize":
        if "--gate-init" in sys.argv:
            fetch(base, "/gate/initialize")
        result = {"abi": "webhtv-ipc-v1", "capabilities": ["home", "category", "search"]}
    elif method in ("shutdown", "destroy", "$/heartbeat"):
        result = {}
    else:
        result = fetch(base, "/gate/" + request_id)
    reply = {"jsonrpc": "2.0", "id": request_id}
    if result.get("fixtureError"):
        reply["error"] = {"code": -32000, "message": "deliberate late probe failure"}
    else:
        reply["result"] = result
    body = json.dumps(reply).encode()
    with _output_lock:
        sys.stdout.buffer.write(("Content-Length: %d\r\n\r\n" % len(body)).encode() + body)
        sys.stdout.buffer.flush()
    fetch(base, "/sent", {"id": request_id})


# Also loadable by the repository's actual Python host.
class Spider:
    def init(self, extend):
        self.base = json.loads(extend)["base"]

    def capabilities(self):
        return ["home", "category", "search"]

    def _probe(self, method, params, context):
        request_id = context.request_id
        fetch(self.base, "/frame", {"id": request_id, "method": method, "params": params})
        result = fetch(self.base, "/gate/" + request_id)
        fetch(self.base, "/observed", {"id": request_id, "cancelled": context.cancelled})
        if result.get("fixtureError"):
            raise RuntimeError("deliberate late probe failure")
        return result

    def home(self, params, context):
        return self._probe("home", params, context)

    def category(self, params, context):
        return self._probe("category", params, context)

    def search(self, params, context):
        return self._probe("search", params, context)

    def destroy(self):
        pass


if __name__ == "__main__":
    base = sys.argv[1]
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            break
        length = int(line.decode().split(":", 1)[1])
        while sys.stdin.buffer.readline().strip():
            pass
        frame = json.loads(sys.stdin.buffer.read(length))
        fetch(base, "/frame", frame)
        threading.Thread(target=answer, args=(base, frame), daemon=True).start()
