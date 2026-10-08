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

    # ------------------------------------------------------------------
    # Phase 5 · 安卓 T4 网关与同步（docs/phase5/design/03 §4.1）
    # ------------------------------------------------------------------

    ANDROID_FIXTURES = "packages/test-fixtures/android"

    def android_fixture(self, name: str):
        return load_json(f"{self.ANDROID_FIXTURES}/{name}")

    def test_android_fixtures_are_parseable_json(self):
        """1 · 全部可解析为 JSON（无语法错误）。"""
        broken: list[str] = []
        for path in sorted((ROOT / self.ANDROID_FIXTURES).glob("*.json")):
            try:
                json.loads(path.read_text(encoding="utf-8"))
            except ValueError as error:  # pragma: no cover - 失败即缺陷
                broken.append(f"{path.name}: {error}")
        self.assertEqual([], broken, f"非法 JSON fixture: {broken}")

    def test_android_gateway_config_site_count(self):
        """2 · 站点数 = 170（快照未被意外截断）。"""
        config = self.android_fixture("gateway-config.json")
        self.assertEqual(170, len(config["sites"]))

    def test_android_gateway_config_types_are_string_four(self):
        """3 · 所有站点 `type` 都是字符串 `"4"`（契约不变）。

        字符串而非整数：PC 的 `asInt` 兼容这两种写法，但契约快照必须锁住真实形态，
        否则将来网关改成数字时，测不出"我们照着旧快照写死了"。
        """
        config = self.android_fixture("gateway-config.json")
        types = {site["type"] for site in config["sites"]}
        self.assertEqual({"4"}, types)

    def test_android_gateway_config_uses_host_placeholder(self):
        """4 · 站点 `api` 全部含 `__HOST__` 占位符（脱敏完整，无真实地址残留）。"""
        text = (ROOT / self.ANDROID_FIXTURES / "gateway-config.json").read_text(
            encoding="utf-8"
        )
        config = json.loads(text)
        self.assertIn("__HOST__", text)
        outside = [
            site["api"]
            for site in config["sites"]
            if "http://__HOST__" not in site["api"]
        ]
        self.assertEqual([], outside, f"存在未占位化的站点地址: {outside[:3]}")
        for leaked in ("192.168.", "172.16.", "10.0.2.2"):
            self.assertNotIn(leaked, text, f"快照里残留了真实地址前缀 {leaked}")

    def test_android_device_fixture_has_no_real_fingerprint(self):
        """5 · 无真实设备指纹（uuid/serial/wlan 为固定假值）。"""
        device = self.android_fixture("device.json")
        self.assertEqual("fixture-device-uuid", device["uuid"])
        self.assertEqual("fixture0", device["serial"])
        self.assertEqual("00:00:00:00:00:00", device["wlan"])

    def test_android_device_fixture_fields_complete(self):
        """6 · `device.json` 含全部 8 个字段（契约完整）。"""
        device = self.android_fixture("device.json")
        for key in ("eth", "ip", "name", "serial", "time", "type", "uuid", "wlan"):
            self.assertIn(key, device, f"device.json 缺少字段 {key}")

    def test_android_history_fixture_covers_sentinel(self):
        """7 · `history-android.json` 覆盖 `Long.MIN_VALUE` 哨兵值。

        这是最容易悄悄写错的一处（PC 的 `int` 放不下 `Long.MIN_VALUE`），
        快照里必须留一条带哨兵的记录，否则反向验证 #4 无从触发。
        """
        history = self.android_fixture("history-android.json")
        sentinel = -9223372036854775808
        self.assertTrue(
            any(
                item.get("opening") == sentinel and item.get("ending") == sentinel
                for item in history
            ),
            "history fixture 缺少哨兵值记录",
        )
        # 毫秒单位（不是秒）：不存在换算，值必须是 13 位量级。
        for item in history:
            self.assertGreater(
                item["createTime"], 10**12, "createTime 不是毫秒时间戳"
            )

    def test_android_history_fixture_covers_two_segment_key(self):
        """7b · 覆盖缺段 key（`a@@@b` → cid=0）与合法 key。"""
        history = self.android_fixture("history-android.json")
        segments = [len(item["key"].split("@@@")) for item in history]
        self.assertIn(3, segments, "缺少三段 key")
        self.assertIn(2, segments, "缺少两段 key（cid 缺省的容错路径）")

    def test_android_sync_options_fixture_shape(self):
        """7c · `SyncOptions` 形态含全部 12 个键（PC 只发子集，但契约要完整）。"""
        options = self.android_fixture("sync-options.json")
        expected = {
            "config",
            "spider",
            "search",
            "history",
            "keep",
            "follow",
            "webHome",
            "settings",
            "loginState",
            "remoteRelay",
            "mpvConfig",
            "paths",
        }
        self.assertEqual(expected, set(options))

    def test_android_backup_fixture_prefers_whitelist(self):
        """7d · `Backup.prefers` 含 PC 白名单键与必须被排除的凭据键。"""
        backup = self.android_fixture("backup-android.json")
        self.assertIn("prefers", backup)
        self.assertIn("tmdb_config", backup["prefers"])
        self.assertIn("history", backup)
        self.assertIn("keep", backup)

    def test_android_fixtures_are_complete(self):
        """8 · 目录清单完整（少一个文件就等于少一条验收路径）。"""
        required = [
            "gateway-config.json",
            "gateway-config-empty.json",
            "gateway-config-mismatch.json",
            "gateway-config-loopback.json",
            "gateway-config-repo.json",
            "device.json",
            "history-android.json",
            "keep-android.json",
            "backup-android.json",
            "sync-options.json",
            "vod-home.json",
        ]
        missing = [
            name
            for name in required
            if not (ROOT / self.ANDROID_FIXTURES / name).is_file()
        ]
        self.assertEqual([], missing, f"缺少安卓 fixture: {missing}")

    def test_unknown_android_fields_are_preserved(self):
        """9 · 未识别的字段不被丢弃（历史 raw 保留 TMDB 字段的前提）。

        对应 `design/02` §3.4 表："TMDB 字段保留在 raw"。若 fixture 被"精简"过，
        PC 侧的 raw 保真断言就成了自证。
        """
        history = self.android_fixture("history-android.json")
        first = history[0]
        for key in (
            "tmdbId",
            "mediaType",
            "tmdbSeasonNumber",
            "tmdbEpisodeNumber",
            "sourceBindingKey",
            "speed",
            "scale",
            "player",
        ):
            self.assertIn(key, first, f"history fixture 缺少字段 {key}")


if __name__ == "__main__":
    unittest.main()
