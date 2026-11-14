"""CatVod 垫片包（T3 的 Python 侧兼容层）。

CatVod 生态的 Python 蜘蛛普遍写 `from base.spider import Spider`。
这里提供同名包，使这类站源能在本项目的 Python sidecar 里运行。
只做协议与基础设施垫片，不包含任何站点逻辑，也不联网。
"""

from .spider import Spider

__all__ = ["Spider"]
