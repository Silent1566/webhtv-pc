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

    # ------------------------------------------------------------------
    # Phase 4 · TMDB 元数据增强（docs/phase4/design/03 §5、design/05 §4.3）
    # ------------------------------------------------------------------

    TMDB_SCHEMA = "packages/protocol/schema/tmdb-config.schema.json"

    def test_tmdb_config_full_is_valid(self):
        schema = load_json(self.TMDB_SCHEMA)
        fixture = load_json("packages/test-fixtures/tmdb/config/tmdb-config-full.json")
        Draft202012Validator(schema).validate(fixture)

    def test_tmdb_config_alias_keys_are_valid(self):
        schema = load_json(self.TMDB_SCHEMA)
        fixture = load_json("packages/test-fixtures/tmdb/config/tmdb-config-alias.json")
        Draft202012Validator(schema).validate(fixture)

    def test_tmdb_config_invalid_is_rejected(self):
        """反向验证：非法配置必须校验失败，否则 schema 形同虚设。"""
        schema = load_json(self.TMDB_SCHEMA)
        fixture = load_json("packages/test-fixtures/tmdb/config/tmdb-config-invalid.json")
        errors = list(Draft202012Validator(schema).iter_errors(fixture))
        self.assertTrue(errors, "非法 TMDB 配置竟然通过了 schema 校验")

    def test_tmdb_config_unknown_fields_are_preserved_by_fixture(self):
        """未知字段必须保留（与 config.schema.json 同一契约）。"""
        fixture = load_json("packages/test-fixtures/tmdb/config/tmdb-config-full.json")
        self.assertEqual({"must": "be preserved"}, fixture["futureField"])

    def test_tmdb_fixtures_are_complete(self):
        """docs/phase4/design/05 §2.1 列出的 fixture 必须全部存在。"""
        required = [
            "configuration.json",
            "search-multi.json",
            "search-empty.json",
            "search-split-season.json",
            "detail-tv.json",
            "detail-tv-next-air.json",
            "detail-movie.json",
            "season-1.json",
            "season-2.json",
            "season-0.json",
            "season-empty.json",
            "episode-s1e1.json",
            "person.json",
            "videos-tv.json",
            "recommendations-page1.json",
            "recommendations-page2.json",
            "recommendations-empty.json",
            "error-401.json",
            "error-500.json",
            "malformed.json",
            "config/tmdb-config-full.json",
            "config/tmdb-config-alias.json",
            "config/tmdb-config-invalid.json",
        ]
        missing = [
            name
            for name in required
            if not (ROOT / "packages" / "test-fixtures" / "tmdb" / name).is_file()
        ]
        self.assertEqual([], missing, f"缺少 TMDB fixture: {missing}")


if __name__ == "__main__":
    unittest.main()
