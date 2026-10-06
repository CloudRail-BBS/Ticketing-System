#!/usr/bin/env python3
"""静态校验前端资源：.gjs 模板的作用域，以及剥离模板后的 JS 语法。

为什么需要这个脚本
------------------

Discourse 的 `.gjs` 模板跑在**严格模式**下：模板里出现的每一个辅助函数、组件、
修饰符，都必须在同一文件的 JS 部分显式 import。漏掉一个的后果不是「少一个按钮」，
而是 `ember-template-imports` 在构建期报 "X is not in scope"，Discourse 的
js_compiler 捕获后把**整个插件 bundle** 替换成一行 `throw new Error(...)`。

症状因此极具误导性：路由注册不上、所有组件失效、页面空白，控制台只有一条指向
`discourse/plugins/…/_app_/…` 的报错，而那条报错并不告诉你是哪个模板、哪个名字。
如果这个插件里同时有十几个模板，定位只能靠二分。

这个脚本把那个构建期错误提前到本地、并且指出**文件 + 名字**。

检查项
------

1. 模板作用域：模板里用到的每个非关键字名字，必须在文件顶部 import 过，
   或者是块参数（`as |row|`）—— 块参数是局部绑定，不需要 import。
2. JS 语法：把 `<template>` 块从源码里剥掉，剩下的 JS 写成 .mjs 交给
   `node --check`。这一步能抓住括号不配对、装饰器用错位置之类的低级错误。
   （没有 node 时跳过，只报警告，不让整个脚本失败。）
3. 相对导入可达性：`import ... from "./x"` / `"../../lib/y"` 必须指向真实存在的
   文件（自动补 `.js` / `.gjs` / `.mjs`）。写错一个相对路径同样是整包失效。

用法
----

    python scripts/check-templates.py            # 校验
    python scripts/check-templates.py --verbose  # 同时打印每个文件的作用域统计
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

PLUGIN_ROOT = Path(__file__).resolve().parent.parent
FRONTEND_ROOT = PLUGIN_ROOT / "assets" / "javascripts" / "discourse"

# 模板里可以出现、但**不需要** import 的名字。
#
# 这些都是 Glimmer 的关键字（语言的一部分，不是注册出来的辅助函数）。
# 注意 `on` / `fn` / `get` / `action` **不在**这个表里：它们是真实存在的辅助函数，
# 严格模式下必须 import —— 把它们当成关键字正是漏 import 的常见来源。
KEYWORDS = {
    "if",
    "unless",
    "each",
    "each-in",
    "let",
    "with",
    "in-element",
    "-in-element",
    "-track-array",
    "yield",
    "has-block",
    "has-block-params",
    "outlet",
    "mount",
    "component",
    "helper",
    "modifier",
    "debugger",
    "log",
    "else",
    "unbound",
    "this",
}

TEMPLATE_OPEN = "<template>"
TEMPLATE_CLOSE = "</template>"

# {{name …}} / {{#name …}} / {{/name}} / {{!name}} —— 只取头部的标识符。
# 开头的 `~` 是空白控制符，`#` `/` `!` `>` `&` 是各种语法前缀。
MUSTACHE_RE = re.compile(r"\{\{~?\s*[#>!&/]?\s*([A-Za-z_$][\w$-]*)")

# 子表达式 (name …) —— 只在模板体内扫描，所以不会碰到 JS。
SUBEXPR_RE = re.compile(r"\(\s*([a-z][\w$-]*)\s")

# 尖括号调用：<ComponentName …> / <ComponentName/>。HTML 标签是小写的，不会命中。
ANGLE_RE = re.compile(r"<([A-Z][\w$]*)[\s/>]")

# 块参数：`as |row|` / `as |a b|`
BLOCK_PARAM_RE = re.compile(r"\bas\s*\|([^|]*)\|")

# 注释：{{!-- --}} 与 {{! }}
COMMENT_RE = re.compile(r"\{\{!--[\s\S]*?--\}\}|\{\{![\s\S]*?\}\}")

# import 语句
NAMED_IMPORT_RE = re.compile(r"^\s*import\s*\{([^}]*)\}\s*from", re.MULTILINE)
DEFAULT_IMPORT_RE = re.compile(
    r"^\s*import\s+([A-Za-z_$][\w$]*)\s*(?:,\s*\{[^}]*\})?\s*from", re.MULTILINE
)
RELATIVE_IMPORT_RE = re.compile(r"""from\s+["'](\.[^"']*)["']""")

RESOLVE_SUFFIXES = ("", ".js", ".gjs", ".mjs", "/index.js", "/index.gjs")


class Problem(Exception):
    pass


def extract_templates(source: str) -> tuple[list[str], str]:
    """返回 (模板体列表, 把模板换成占位表达式后的 JS)。

    用深度计数而不是正则：Glimmer 允许嵌套 `<template>`（例如把模板当参数传给
    组件），而 `.*?` 会在第一个 `</template>` 处停下，把一半模板当成 JS。

    剥离时**不能**直接删掉模板。`export default <template>…</template>` 删掉模板
    就变成一句没有右值的 `export default`，而类体里的 `<template>` 删掉之后剩下
    一个孤立的标识符 —— 两种写法都会让 `node --check` 报语法错，而那是假阳性，
    会把真实的错误淹掉。换成一个赋值表达式占位，两种位置都成立：

        export default __gjs_template__ = null;    // 顶层：赋值表达式
        __gjs_template__ = null;                   // 类体：带初值的字段
    """
    bodies: list[str] = []
    js_parts: list[str] = []
    cursor = 0

    while True:
        start = source.find(TEMPLATE_OPEN, cursor)
        if start == -1:
            break

        js_parts.append(source[cursor:start])
        js_parts.append("__gjs_template__ = null;")

        depth = 1
        scan = start + len(TEMPLATE_OPEN)
        while depth > 0:
            nxt_open = source.find(TEMPLATE_OPEN, scan)
            nxt_close = source.find(TEMPLATE_CLOSE, scan)
            if nxt_close == -1:
                raise Problem("出现 <template> 但没有配对的 </template>")
            if nxt_open != -1 and nxt_open < nxt_close:
                depth += 1
                scan = nxt_open + len(TEMPLATE_OPEN)
            else:
                depth -= 1
                scan = nxt_close + len(TEMPLATE_CLOSE)

        body_end = scan - len(TEMPLATE_CLOSE)
        bodies.append(source[start + len(TEMPLATE_OPEN) : body_end])
        cursor = scan

    js_parts.append(source[cursor:])
    return bodies, "".join(js_parts)


# 装饰器：`@service currentUser;` / `@service("ticketing-system") x;` / `@action`
#
# `node --check` 不认识装饰器（它是 stage-3 提案，Node 的默认解析器不开），
# 而 `.gjs` 里 `@service` / `@tracked` / `@action` 到处都是 —— 不剥掉的话每个文件
# 都会报一条假语法错。锚定行首的 `@` 是安全的：`@` 在 JS 里只出现在装饰器和
# 字符串里，而字符串里的 `@`（`"@glimmer/component"`）不在行首。
DECORATOR_RE = re.compile(r"^[ \t]*@[A-Za-z_$][\w$]*(?:\([^()]*\))?[ \t]*", re.MULTILINE)


def strip_decorators(js: str) -> str:
    return DECORATOR_RE.sub("", js)



def imported_names(source: str) -> set[str]:
    names: set[str] = set()

    for clause in NAMED_IMPORT_RE.findall(source):
        for piece in clause.split(","):
            piece = piece.strip()
            if not piece:
                continue
            # `a as b` 绑定的是 b
            local = piece.split(" as ")[-1].strip()
            if local:
                names.add(local)

    names.update(DEFAULT_IMPORT_RE.findall(source))
    return names


def template_usages(body: str) -> tuple[set[str], set[str]]:
    """返回 (需要 import 的名字, 该模板内的块参数)。"""
    cleaned = COMMENT_RE.sub("", body)

    block_params: set[str] = set()
    for clause in BLOCK_PARAM_RE.findall(cleaned):
        block_params.update(clause.split())

    names = set(MUSTACHE_RE.findall(cleaned))
    names.update(ANGLE_RE.findall(cleaned))

    # 子表达式：只保留看起来像辅助函数的（小写开头）。命中的通常是我自己写错了，
    # 所以宁可多报一条让人看一眼。
    names.update(SUBEXPR_RE.findall(cleaned))

    # 关键字与块参数都是局部可用的，不需要 import。
    return names - block_params - KEYWORDS, block_params


def check_relative_imports(path: Path, source: str) -> list[str]:
    problems = []
    for spec in RELATIVE_IMPORT_RE.findall(source):
        base = (path.parent / spec).resolve()
        if any((base.parent / (base.name + suffix)).exists() for suffix in RESOLVE_SUFFIXES):
            continue
        if Path(str(base) + ".js").exists() or Path(str(base) + ".gjs").exists():
            continue
        problems.append(f"{spec} 无法解析到任何文件")
    return problems


def node_check(js: str, label: str) -> str | None:
    node = shutil.which("node")
    if not node:
        return None

    with tempfile.TemporaryDirectory() as tmp:
        target = Path(tmp) / "snippet.mjs"
        target.write_text(strip_decorators(js), encoding="utf-8")
        result = subprocess.run(
            [node, "--check", str(target)],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            return None

        lines = [
            line.strip()
            for line in (result.stderr or result.stdout).splitlines()
            if line.strip()
        ]
        location = lines[0] if lines else "?"
        # node 的输出是「路径:行号 / 源码行 / 插入符 / 空行 / SyntaxError: …」。
        # 取带 Error 的那一行才是人要看的信息，只留前三行会把关键行切掉。
        reason = next(
            (line for line in lines if "Error" in line),
            lines[-1] if lines else "未知错误",
        )
        return f"{label}: {reason}（{Path(location).name}:{location.rsplit(':', 1)[-1]}）"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    if not FRONTEND_ROOT.is_dir():
        print(f"找不到前端目录：{FRONTEND_ROOT}", file=sys.stderr)
        return 2

    files = sorted(
        p
        for p in FRONTEND_ROOT.rglob("*")
        if p.is_file() and p.suffix in {".js", ".gjs", ".mjs"}
    )

    failures: list[str] = []
    warnings: list[str] = []
    checked = 0

    for path in files:
        rel = path.relative_to(PLUGIN_ROOT).as_posix()
        try:
            source = path.read_text(encoding="utf-8")
            bodies, js = extract_templates(source)
        except Problem as error:
            failures.append(f"{rel}: {error}")
            continue

        bound = imported_names(source)

        for index, body in enumerate(bodies, start=1):
            used, block_params = template_usages(body)
            missing = sorted(name for name in used if name not in bound)

            # 单模板文件（绝大多数）不必标出序号。
            where = f"模板 #{index}" if len(bodies) > 1 else "模板"

            if missing:
                failures.append(
                    f"{rel} ({where}): 使用了未 import 的名字 → {', '.join(missing)}"
                )

            if args.verbose:
                print(
                    f"  {rel} {where}: "
                    f"{len(used)} 个名字, {len(block_params)} 个块参数"
                )

        for problem in check_relative_imports(path, source):
            failures.append(f"{rel}: 相对导入 {problem}")

        # JS 语法。`.gjs` 的模板已经剥掉，剩下的应当是一段合法 ESM。
        js_error = node_check(js, rel)
        if js_error is not None:
            if shutil.which("node"):
                failures.append(js_error)
            else:
                warnings.append(f"{rel}: 未找到 node，跳过 JS 语法检查")

        checked += 1

    for warning in warnings:
        print(f"warn  {warning}")

    if failures:
        print()
        for failure in failures:
            print(f"FAIL  {failure}")
        print(f"\n{len(failures)} 处问题，共检查 {checked} 个文件。")
        return 1

    print(f"OK  检查了 {checked} 个文件，模板作用域与 JS 语法均通过。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
