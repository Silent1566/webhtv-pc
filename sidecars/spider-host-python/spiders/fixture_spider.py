#!/usr/bin/env python3
"""正常站源：通过本地 fixture 服务提供 home/category/detail/search/play。

用途：作为「最小 sidecar 宿主 + 进程隔离」验收里**成功路径**的样本，
同时充当「≥3 个可重复 CatSpider HTTP 样本」中 sidecar 侧的对照实现。

它只依赖标准库，通过环境变量或 manifest `extend` 取得 fixture 基地址，因此
不引入任何第三方依赖（设计文档 §20.3「按需下载或内置 sidecar」）。
"""

from __future__ import annotations

import json
import os
import urllib.request
from collections.abc import Mapping
from typing import Any

DEFAULT_BASE = "http://127.0.0.1:18080"
USER_AGENT = "WebHTV-PC/0.1 (Windows)"


class Spider:
    key = "sidecar-fixture"

    def __init__(self, manifest: Mapping[str, Any] | None = None):
        self.manifest = dict(manifest or {})
        config = self.manifest.get("config") or {}
        self.base = os.environ.get("WEBHTV_FIXTURE_BASE") or config.get(
            "base", DEFAULT_BASE
        )
        self.play_media = config.get("playMedia", "/media/sample.m3u8")
        self.default_extend = config.get("extend", "")

    # ------------------------------------------------------------ 生命周期

    def init(self, extend: str) -> dict:
        return {"key": self.key, "extend": extend, "base": self.base}

    def close(self) -> None:
        pass

    def capabilities(self) -> list[str]:
        return ["home", "category", "detail", "search", "play"]

    # ---------------------------------------------------------------- 方法

    def _get_json(self, path: str) -> Any:
        # 只允许 http(s)：fixture 基地址来自 manifest/extend，不允许 file:// 等 scheme。
        if not self.base.startswith(("http://", "https://")):
            raise ValueError(f"站源基地址必须是 http(s)：{self.base}")
        request = urllib.request.Request(  # noqa: S310 - scheme 已在上面校验
            f"{self.base}{path}",
            headers={"User-Agent": USER_AGENT},
        )
        with urllib.request.urlopen(request, timeout=10) as response:  # noqa: S310
            payload = response.read()
        return json.loads(payload.decode("utf-8"))

    def home(self, params: Mapping[str, Any], context) -> dict:
        context.check_cancelled()
        result = self._get_json("/api/type1/")
        return {
            "class": result.get("class", []),
            "filters": result.get("filters", {}),
            "list": result.get("list", []),
        }

    def category(self, params: Mapping[str, Any], context) -> dict:
        context.check_cancelled()
        type_id = params.get("id") or params.get("t") or "1"
        page = _page_of(params)
        result = self._get_json(f"/api/type1/?t={type_id}&pg={page}")
        return {
            "class": result.get("class", []),
            "filters": result.get("filters", {}),
            "list": result.get("list", []),
            "page": page,
            "pagecount": 2,
            "total": len(result.get("list", [])) * 2,
        }

    def detail(self, params: Mapping[str, Any], context) -> dict:
        context.check_cancelled()
        vod_id = params.get("id") or params.get("ids") or ""
        result = self._get_json(f"/api/type1/?ac=detail&ids={vod_id}")
        return {"list": result.get("list", [])}

    def search(self, params: Mapping[str, Any], context) -> dict:
        context.check_cancelled()
        keyword = params.get("keyword") or params.get("wd") or ""
        context.check_cancelled()
        if not keyword:
            raise ValueError("缺少 keyword")
        result = self._get_json(f"/api/type1/?wd={keyword}&pg=1")
        return {
            "list": result.get("list", []),
            "page": 1,
            "pagecount": 1,
        }

    def play(self, params: Mapping[str, Any], context) -> dict:
        context.check_cancelled()
        flag = params.get("flag") or "sidecar"
        target = params.get("id") or ""
        if "," in str(target):
            url, _, play_flag = str(target).partition(",")
            if play_flag:
                flag = play_flag
        else:
            url = target
        if not url:
            raise ValueError("缺少 id")
        return {"url": url, "flag": flag, "format": "application/vnd.apple.mpegurl", "header": {}}

    def destroy(self) -> None:
        pass


def _page_of(params: Mapping[str, Any]) -> int:
    raw = params.get("page")
    if raw is None:
        return 1
    try:
        value = int(str(raw))
    except (TypeError, ValueError):
        return 1
    return value if value >= 1 else 1


def create_spider(manifest: Mapping[str, Any] | None = None) -> Spider:
    return Spider(manifest)
