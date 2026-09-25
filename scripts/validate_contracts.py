#!/usr/bin/env python3
"""验证 WebHTV PC Phase 0 的配置协议与 Spider ABI 契约。"""

import json
import sys
from pathlib import Path

try:
    from jsonschema import Draft202012Validator
except ImportError:
    print("错误：缺少 jsonschema，请安装后重试。", file=sys.stderr)
    raise SystemExit(2)

ROOT = Path(__file__).resolve().parents[1]


def load_json(relative_path: str):
    path = ROOT / relative_path
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def validate(instance, schema_path: str, label: str) -> None:
    schema = load_json(schema_path)
    validator = Draft202012Validator(schema)
    errors = sorted(validator.iter_errors(instance), key=lambda error: list(error.path))
    if errors:
        print(f"失败：{label}", file=sys.stderr)
        for error in errors:
            location = ".".join(str(part) for part in error.path) or "<root>"
            print(f"  {location}: {error.message}", file=sys.stderr)
        raise SystemExit(1)
    print(f"通过：{label}")


def main() -> None:
    validate(
        load_json("packages/protocol/fixtures/config/minimal-tvbox.json"),
        "packages/protocol/schema/config.schema.json",
        "最小 TVBox 配置",
    )

    manifest = {
        "abi": "webhtv-ipc-v1",
        "abiMinor": 0,
        "key": "fixture",
        "name": "Fixture Spider",
        "runtime": "node-22",
        "entry": "dist/index.js",
        "capabilities": ["home", "category", "detail", "search", "play"],
        "permissions": {
            "network": True,
            "localProxy": False,
            "ui": False,
            "storage": "cache-only",
            "process": False,
            "clipboard": False,
            "browser": False,
        },
        "limits": {
            "memoryMiB": 256,
            "cpuSeconds": 30,
            "concurrency": 2,
            "responseMiB": 8,
        },
    }
    validate(
        manifest,
        "packages/spider-abi/schema/manifest.schema.json",
        "Spider manifest",
    )

    message_schema = "packages/spider-abi/schema/message.schema.json"
    messages = {
        "IPC 请求": {
            "jsonrpc": "2.0",
            "id": "1",
            "method": "home",
            "params": {},
            "deadlineMs": 5000,
        },
        "IPC 成功响应": {"jsonrpc": "2.0", "id": "1", "result": {"list": []}},
        "IPC 错误响应": {
            "jsonrpc": "2.0",
            "id": "1",
            "error": {
                "code": "SPIDER_TIMEOUT",
                "message": "timeout",
                "retryable": True,
            },
        },
        "IPC 取消请求": {
            "jsonrpc": "2.0",
            "method": "$/cancel",
            "params": {"id": "1"},
        },
    }
    for label, message in messages.items():
        validate(message, message_schema, label)

    print("全部 Phase 0 契约验证通过。")


if __name__ == "__main__":
    main()
