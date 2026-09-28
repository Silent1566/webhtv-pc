import json
import unittest
from pathlib import Path

from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[1]


def load_json(path: str):
    return json.loads((ROOT / path).read_text(encoding="utf-8"))


class ContractTests(unittest.TestCase):
    def test_minimal_config_is_valid(self):
        schema = load_json("packages/protocol/schema/config.schema.json")
        fixture = load_json("packages/test-fixtures/config/minimal-tvbox.json")
        Draft202012Validator(schema).validate(fixture)

    def test_unknown_config_fields_are_preserved_by_fixture(self):
        fixture = load_json("packages/test-fixtures/config/minimal-tvbox.json")
        self.assertEqual({"must": "be preserved"}, fixture["futureTopLevel"])
        self.assertEqual("must-be-preserved", fixture["sites"][0]["futureField"])

    def test_forbidden_spider_permissions_are_rejected(self):
        schema = load_json("packages/spider-abi/schema/manifest.schema.json")
        manifest = {
            "abi": "webhtv-ipc-v1",
            "abiMinor": 0,
            "key": "unsafe",
            "name": "Unsafe",
            "runtime": "node-22",
            "entry": "index.js",
            "capabilities": ["home"],
            "permissions": {
                "network": True,
                "localProxy": False,
                "ui": True,
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
        errors = list(Draft202012Validator(schema).iter_errors(manifest))
        self.assertTrue(errors)

    def test_request_requires_deadline(self):
        schema = load_json("packages/spider-abi/schema/message.schema.json")
        request = {"jsonrpc": "2.0", "id": "1", "method": "home", "params": {}}
        errors = list(Draft202012Validator(schema).iter_errors(request))
        self.assertTrue(errors)


if __name__ == "__main__":
    unittest.main()
