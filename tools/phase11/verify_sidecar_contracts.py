#!/usr/bin/env python3
"""Phase 11 sidecar 纪律门禁（G11.1–G11.4）。

这些校验项锁的都是「看起来可以顺手改、一改就静默出错」的地方：没有断言盯着，
下一次重构就会把它们改回去，而故障不会当场抛异常。

校验项：

- G11.1 `base/spider.py` 的 `html` 必须是**实例方法**：`Atvp.py:641-642` 用未绑定
  调用 `HostSpider.html(instance, sanitized)`。改成 `staticmethod` 后 `instance`
  会被当成 `content`，返回空树而不抛异常。
- G11.2 `base/spider.py` 的 `regStr` 保持 `(text, pattern, index=0)` 参数顺序：
  与 MisaTV/TVBox 的 `regStr(reg, src, group=1)` **同名不同序**。改签名会让所有
  已适配的壳静默取错分组。
- G11.3 `host.py` 的站源类解析必须「显式优先、隐式兜底、歧义报错」：类名叫什么
  都能加载，两可时拒绝而**不猜**。
- G11.4 `webhtv_ipc.py` 的 `destroy` 与 `shutdown` 必须是两个语义：`--hold` 下
  `destroy` 释放站源但不结束服务循环。

退出码：0 = 全绿；1 = 有失败。
"""

from __future__ import annotations

import ast
import json
import os
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SIDECAR = REPO / "sidecars" / "spider-host-python"

failures: list[str] = []
checks: list[str] = []


def ok(name: str, detail: str) -> None:
    checks.append(f"通过：{name}（{detail}）")


def fail(name: str, detail: str) -> None:
    failures.append(f"失败：{name}（{detail}）")


def parse(path: Path) -> ast.Module:
    return ast.parse(path.read_text(encoding="utf-8"), filename=str(path))


def find_class(tree: ast.Module, name: str) -> ast.ClassDef | None:
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef) and node.name == name:
            return node
    return None


def find_method(cls: ast.ClassDef, name: str) -> ast.FunctionDef | None:
    for node in cls.body:
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return node
    return None


def decorator_names(func: ast.FunctionDef) -> list[str]:
    names = []
    for decorator in func.decorator_list:
        if isinstance(decorator, ast.Name):
            names.append(decorator.id)
        elif isinstance(decorator, ast.Attribute):
            names.append(decorator.attr)
    return names


def all_param_names(func: ast.FunctionDef) -> list[str]:
    """位置参数 + keyword-only 参数：`hold` 这类开关必然是 keyword-only。"""
    args = func.args
    return [arg.arg for arg in args.posonlyargs + args.args + args.kwonlyargs]


# --------------------------------------------------------------------- G11.1
def check_html_is_instance_method() -> None:
    path = SIDECAR / "base" / "spider.py"
    cls = find_class(parse(path), "Spider")
    if cls is None:
        fail("G11.1 html 实例方法", "base/spider.py 里找不到 Spider 类")
        return
    func = find_method(cls, "html")
    if func is None:
        fail("G11.1 html 实例方法", "Spider 类没有 html 方法")
        return
    banned = {"staticmethod", "classmethod", "property"}
    hit = banned.intersection(decorator_names(func))
    if hit:
        fail(
            "G11.1 html 实例方法",
            f"html 被标记为 {sorted(hit)}；Atvp.py:641-642 用未绑定调用 "
            "HostSpider.html(instance, ...)，改掉会把 instance 当成 content",
        )
        return
    args = all_param_names(func)
    if args[:2] != ["self", "content"]:
        fail("G11.1 html 实例方法", f"html 参数应为 (self, content)，实际 {args}")
        return
    ok("G11.1 html 实例方法", "def html(self, content)，无 staticmethod/classmethod")


# --------------------------------------------------------------------- G11.2
def check_reg_str_signature() -> None:
    path = SIDECAR / "base" / "spider.py"
    cls = find_class(parse(path), "Spider")
    func = find_method(cls, "regStr") if cls else None
    if func is None:
        fail("G11.2 regStr 参数顺序", "找不到 Spider.regStr")
        return
    args = all_param_names(func)
    if args != ["self", "text", "pattern", "index"]:
        fail(
            "G11.2 regStr 参数顺序",
            f"regStr 参数应为 (self, text, pattern, index)，实际 {args}；"
            "MisaTV 的 regStr(reg, src, group=1) 同名不同序，改动会让已适配的壳取错分组",
        )
        return
    defaults = [ast.unparse(item) for item in func.args.defaults]
    if defaults != ["0"]:
        fail("G11.2 regStr 参数顺序", f"index 默认值应为 0，实际 {defaults}")
        return
    ok("G11.2 regStr 参数顺序", "def regStr(self, text, pattern, index=0)")


# --------------------------------------------------------------------- G11.3
SAMPLE_RENAMED = textwrap.dedent(
    """
    class MyCatVodSpider:
        key = "renamed"

        def homeContent(self, filter):
            return {"class": [{"type_id": "1", "type_name": "改名后仍可用"}]}
    """
)

SAMPLE_AMBIGUOUS = textwrap.dedent(
    """
    class AlphaSpider:
        def homeContent(self, filter):
            return {}

    class BetaSpider:
        def homeContent(self, filter):
            return {}
    """
)

MANIFEST = {
    "key": "g11",
    "name": "G11 样本",
    "runtime": "python",
    "entry": "spider.py",
    "capabilities": ["home"],
    "permissions": {"network": True},
    "limits": {"memoryMiB": 64, "cpuSeconds": 30, "concurrency": 1, "responseMiB": 8},
}


def run_host(directory: Path, manifest: dict) -> subprocess.CompletedProcess:
    manifest_path = directory / "manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False), encoding="utf-8"
    )
    # 必须钉住子进程的 stdio 编码：sidecar 的 `log()` 走 print(stderr)，Windows 下
    # 默认按控制台代码页（GBK）编码，父进程却按 UTF-8 解码 → 中文日志变乱码，
    # 于是「报错里必须点明歧义」这类子串断言会假失败。
    env = {**os.environ, "PYTHONIOENCODING": "utf-8"}
    return subprocess.run(
        [
            sys.executable,
            str(SIDECAR / "host.py"),
            "--entry",
            str(directory / "spider.py"),
            "--manifest",
            str(manifest_path),
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=120,
        cwd=str(directory),
        env=env,
    )


def check_spider_class_resolution() -> None:
    with tempfile.TemporaryDirectory(prefix="g11-class-") as raw:
        directory = Path(raw)

        (directory / "spider.py").write_text(SAMPLE_RENAMED, encoding="utf-8")
        renamed = run_host(directory, MANIFEST)
        if renamed.returncode != 0:
            fail(
                "G11.3 类名放宽",
                f"类名不叫 Spider 时应能加载，实际退出码 {renamed.returncode}："
                f"{renamed.stderr.strip()[:200]}",
            )
            return

        (directory / "spider.py").write_text(SAMPLE_AMBIGUOUS, encoding="utf-8")
        ambiguous = run_host(directory, MANIFEST)
        if ambiguous.returncode == 0:
            fail("G11.3 类名放宽", "两个候选类时应拒绝，实际却启动成功（在猜）")
            return
        if "多个候选" not in ambiguous.stderr:
            fail(
                "G11.3 类名放宽",
                f"拒绝时的报错必须点明歧义，实际 stderr：{ambiguous.stderr.strip()[:200]}",
            )
            return

        resolved = run_host(directory, {**MANIFEST, "className": "BetaSpider"})
        if resolved.returncode != 0:
            fail(
                "G11.3 类名放宽",
                f"manifest 指定 className 后应能加载，实际 {resolved.returncode}："
                f"{resolved.stderr.strip()[:200]}",
            )
            return

    ok(
        "G11.3 类名放宽",
        "非 Spider 类名可加载、歧义时拒绝、className 可消歧",
    )


# --------------------------------------------------------------------- G11.4
def check_hold_semantics() -> None:
    source = (SIDECAR / "webhtv_ipc.py").read_text(encoding="utf-8")
    tree = ast.parse(source, filename="webhtv_ipc.py")
    cls = find_class(tree, "SidecarServer")
    if cls is None:
        fail("G11.4 hold 语义", "找不到 SidecarServer")
        return

    init = find_method(cls, "__init__")
    params = all_param_names(init) if init else []
    if "hold" not in params:
        fail("G11.4 hold 语义", "SidecarServer.__init__ 缺少 hold 参数")
        return

    destroy = find_method(cls, "_handle_destroy")
    shutdown = find_method(cls, "_handle_shutdown")
    if destroy is None or shutdown is None:
        fail("G11.4 hold 语义", "destroy 与 shutdown 必须是两个独立的处理函数")
        return

    destroy_src = ast.unparse(destroy)
    if "if not self.hold" not in destroy_src:
        fail(
            "G11.4 hold 语义",
            "destroy 未按 hold 分支：--hold 下必须不置 _stopping，否则自起取流服务的站源会丢端口",
        )
        return
    if "_stopping = True" not in ast.unparse(shutdown):
        fail("G11.4 hold 语义", "shutdown 必须无条件停机")
        return

    handlers_node = None
    for node in ast.walk(cls):
        # `self._handlers: dict[...] = {...}` 是 AnnAssign，不是 Assign，两者都要覆盖。
        if isinstance(node, ast.Assign):
            if any(
                ast.unparse(target).endswith("self._handlers")
                for target in node.targets
            ):
                handlers_node = node.value
        elif isinstance(node, ast.AnnAssign):
            if ast.unparse(node.target).endswith("self._handlers"):
                handlers_node = node.value
    if handlers_node is None:
        fail("G11.4 hold 语义", "找不到 _handlers 映射")
        return
    # 按 AST 取值而不是比对源码文本：ast.unparse 会把字符串字面量重写成单引号。
    wire = {
        key.value: ast.unparse(value)
        for key, value in zip(handlers_node.keys, handlers_node.values)
        if isinstance(key, ast.Constant) and isinstance(key.value, str)
    }
    if wire.get("shutdown") != "self._handle_shutdown":
        fail(
            "G11.4 hold 语义",
            f"wire 方法 shutdown 必须指向 _handle_shutdown，实际 {wire.get('shutdown')}",
        )
        return
    if wire.get("destroy") != "self._handle_destroy":
        fail(
            "G11.4 hold 语义",
            f"wire 方法 destroy 必须指向 _handle_destroy，实际 {wire.get('destroy')}",
        )
        return

    ok("G11.4 hold 语义", "destroy 按 hold 分支，shutdown 无条件停机")


def main() -> int:
    # 门禁不能依赖调用方的控制台编码：Windows 默认 GBK 时，站源 stderr 里的
    # 非常用字符会让 print 直接抛 UnicodeEncodeError，把「校验通过」变成崩溃。
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if callable(reconfigure):
            reconfigure(encoding="utf-8", errors="replace")

    check_html_is_instance_method()
    check_reg_str_signature()
    check_spider_class_resolution()
    check_hold_semantics()

    for line in checks:
        print(line)
    for line in failures:
        print(line)

    total = len(checks) + len(failures)
    if failures:
        print(f"\n{len(failures)}/{total} 项未通过。")
        return 1
    print(f"\n全部 {total} 项 Phase 11 sidecar 纪律校验通过。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
