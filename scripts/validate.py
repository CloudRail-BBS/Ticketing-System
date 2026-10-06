#!/usr/bin/env python3
"""静态一致性校验。

这个脚本存在的理由只有一个：这个插件里几乎每一种错误的表现都是**沉默**的。

    少一个 i18n 键            → 界面上渲染成 `[en.ticketing_system.foo]`
    少一个 site_setting       → NoMethodError，只在第一次真正读它的时候
    API 路径拼错              → 404 页面，不是异常
    状态枚举加了成员忘了文案  → 下拉框里多一个原始键名
    事件种类加了成员忘了文案  → 时间线上安静地显示成 `auto_closed` 这种机器名
    某个语种少一个键          → 只有那个语种的用户看得见
    errors.add 的键没有条目   → 报错信息变成 `translation missing: …`

没有一条会写日志，没有一条会让测试变红（这个仓库里也没有测试环境）。
所以这些检查必须在这里、在提交之前跑一遍。

用法：
    python scripts/validate.py            # 只报告问题
    python scripts/validate.py --verbose  # 同时打印通过的项目

依赖：PyYAML。退出码非零表示有 ERROR 级问题。
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - 环境问题，不是代码问题
    sys.exit(
        "需要 PyYAML：python -m pip install pyyaml\n"
        "（本脚本刻意只依赖这一个库：其余检查都是纯文本匹配。）"
    )

ROOT = Path(__file__).resolve().parent.parent

# 插件目录名就是仓库里那个目录，同时也是 PLUGIN_NAME 与 settings 的归属来源。
PLUGIN_DIR_NAME = ROOT.name

# 所有 locale 键的顶层命名空间。
NS = "ticketing_system"

LOCALES = ("en", "zh_CN")

SEVERITY_ERROR = "ERROR"
SEVERITY_WARN = "WARN"

findings: list[tuple[str, str, str]] = []  # (severity, 位置, 说明)


def error(where: str, message: str) -> None:
    findings.append((SEVERITY_ERROR, where, message))


def warn(where: str, message: str) -> None:
    findings.append((SEVERITY_WARN, where, message))


# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------


def rel(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT)).replace("\\", "/")
    except ValueError:
        return str(path)


def read(path: Path) -> str:
    # encoding 必须显式给：Windows 的默认编码是 cp936/gbk，
    # 而这个仓库里有大量中文注释，读错会抛 UnicodeDecodeError 而不是静默出错 ——
    # 但错误信息指向行号时会误导。
    return path.read_text(encoding="utf-8")


def sources(pattern: str) -> list[Path]:
    return sorted(p for p in ROOT.glob(pattern) if p.is_file())


def flatten(node, prefix: str = "") -> dict[str, object]:
    """把嵌套 dict 压成 {"a.b.c": 叶子值}。叶子 = 非 dict。"""
    out: dict[str, object] = {}
    if isinstance(node, dict):
        for key, value in node.items():
            child = f"{prefix}.{key}" if prefix else str(key)
            if isinstance(value, dict):
                out.update(flatten(value, child))
            else:
                out[child] = value
    elif prefix:
        out[prefix] = node
    return out


def leaf_kind(value: object) -> str:
    return "map" if isinstance(value, dict) else "value"


# ---------------------------------------------------------------------------
# A. YAML 可解析 + H. 客户端 locale 的 js: 包装
# ---------------------------------------------------------------------------

locales: dict[str, dict] = {}


def check_yaml() -> None:
    paths = sources("config/locales/*.yml") + [ROOT / "config/settings.yml"]

    for path in paths:
        try:
            locales[rel(path)] = yaml.safe_load(read(path)) or {}
        except yaml.YAMLError as exc:
            error(rel(path), f"YAML 无法解析：{exc}")

    for locale in LOCALES:
        path = ROOT / f"config/locales/client.{locale}.yml"
        data = locales.get(rel(path))
        if data is None:
            continue
        # 结构是 `<locale>:` → `js:` → `ticketing_system:`。两层都要查，顺序
        # 不能反：先确认语言键，才知道该去哪儿找 js:。
        #
        # 少语言键，整个文件对 I18n 不可见；少 js: 这一层，客户端所有查询都会
        # 落空而服务端查询照常工作 —— 症状是「界面全是方括号键名，但错误提示
        # 是正常中文」。两种都不报错，只在界面上显形。
        if locale not in data:
            error(rel(path), f"顶层缺少语言键 `{locale}:`（当前顶层键：{list(data)}）")
            continue

        subtree = data[locale]
        if not isinstance(subtree, dict) or "js" not in subtree:
            current = list(subtree) if isinstance(subtree, dict) else subtree
            error(rel(path), f"`{locale}:` 下缺少 `js:` 包装（当前键：{current}）")


def client_keys(locale: str) -> dict[str, object]:
    data = locales.get(f"config/locales/client.{locale}.yml", {})
    return flatten(data.get(locale, {}).get("js", {}), "")


def server_keys(locale: str) -> dict[str, object]:
    data = locales.get(f"config/locales/server.{locale}.yml", {})
    return flatten(data.get(locale, {}), "")


# ---------------------------------------------------------------------------
# B. 两个语种的键集必须一致
# ---------------------------------------------------------------------------


def check_locale_parity() -> None:
    for kind, getter in (("client", client_keys), ("server", server_keys)):
        left, right = getter("en"), getter("zh_CN")
        for key in sorted(set(left) - set(right)):
            error(
                f"config/locales/{kind}.zh_CN.yml",
                f"缺少键 `{key}`（en 有，zh_CN 没有）",
            )
        for key in sorted(set(right) - set(left)):
            error(
                f"config/locales/{kind}.en.yml",
                f"缺少键 `{key}`（zh_CN 有，en 没有）",
            )
        # 一边是字符串、另一边是映射，是最难查的一种：两边「都有这个键」，
        # 但其中一边查下去必然落空。
        for key in sorted(set(left) & set(right)):
            if leaf_kind(left[key]) != leaf_kind(right[key]):
                error(
                    f"config/locales/{kind}.*.yml",
                    f"键 `{key}` 的类型不一致：en 是 {leaf_kind(left[key])}，"
                    f"zh_CN 是 {leaf_kind(right[key])}",
                )


# ---------------------------------------------------------------------------
# C. 前端 i18n 调用 → client.en.yml
# ---------------------------------------------------------------------------

# 三种写法都要覆盖：JS 里的 i18n("…")、模板里的 {{i18n "…"}}、
# 以及 lib/ticketing-system.js 里把 i18n 当参数传进去的 translate("…")。
I18N_LITERAL_RE = re.compile(
    r"""(?:\bi18n|\btranslate|\{\{\s*i18n)\s*\(\s*(["'])(?P<key>[^"'\\]+)\1"""
)
I18N_TEMPLATE_RE = re.compile(
    r"(?:\bi18n|\btranslate|\{\{\s*i18n)\s*\(\s*`(?P<body>[^`]*)`"
)


def check_client_i18n() -> None:
    keys = client_keys("en")

    for path in sources("assets/javascripts/**/*.js") + sources(
        "assets/javascripts/**/*.gjs"
    ):
        text = read(path)
        where = rel(path)

        for match in I18N_LITERAL_RE.finditer(text):
            key = match.group("key")
            if not key.startswith(f"{NS}."):
                continue
            # 插值串不是字面量键（`` i18n(`ticketing_system.${ns}`) `` 走的是
            # 下面那条分支）。漏掉这个判断就会把 `ticketing_system.${ns}` 当成
            # 一个不存在的键来报。
            if "${" in key:
                continue
            if key not in keys:
                line = text.count("\n", 0, match.start()) + 1
                error(where, f"第 {line} 行引用了不存在的客户端键 `{key}`")

        for match in I18N_TEMPLATE_RE.finditer(text):
            body = match.group("body")
            if "${" not in body:
                # 没有插值 → 就是一条普通字面量，上面那条分支已经查过。
                # 不排除的话每条字面量都会被当成「前缀」再报一次假问题。
                continue
            head = body.split("${", 1)[0]
            if not head.startswith(f"{NS}."):
                continue
            prefix = head.rstrip(".")
            # 至少要有三段才值得检查：`ticketing_system.${ns}.${key}` 的前缀是
            # `ticketing_system` 本身，任何键都满足，等于没查。
            if len(prefix.split(".")) < 3:
                continue
            # 用 startswith(prefix) 而不是 startswith(prefix + ".")：拼出来的
            # 那一段常以 `_` 结尾（`…admin.tab_${tab}` → `…admin.tab_overview`），
            # 补一个点反而一个都匹配不上。
            if not any(k.startswith(prefix) for k in keys):
                line = text.count("\n", 0, match.start()) + 1
                error(
                    where,
                    f"第 {line} 行动态拼出的键前缀 `{prefix}.` 在 client.en.yml 里"
                    f"一个都不存在",
                )


# ---------------------------------------------------------------------------
# D. 服务端 i18n / Errors / errors.add → server.en.yml
# ---------------------------------------------------------------------------

RUBY_I18N_LITERAL_RE = re.compile(r"""I18n\.t\(\s*(["'])(?P<key>[^"'\\]+)\1""")
# 注意：这条正则的内容以 `"` 结尾。若用 r"""…""" 定界，结尾会变成 `""""`，
# Python 会解析成「三引号收尾 + 一个裸引号」，于是报 unterminated string literal。
# 凡是正则内容里含 `"` 的，一律改用单引号定界的原始字符串。
RUBY_I18N_DYNAMIC_RE = re.compile(r'I18n\.t\(\s*"(?P<body>[^"]*)"')
ERRORS_NEW_RE = re.compile(r"""Errors::(?P<klass>[A-Za-z_]\w*)\.new\(\s*:(?P<key>\w+)""")
ERRORS_ADD_RE = re.compile(r"""errors\.add\(\s*:(?P<attr>\w+)\s*,\s*:(?P<key>\w+)""")
AR_CLASS_RE = re.compile(r"""class\s+(?P<name>\w+)\s*<\s*ActiveRecord::Base""")

# `Errors::Base#initialize` 把 key 翻成 `ticketing_system.errors.<key>`。
# 只要那一边少一个条目，所有这类错误都会渲染成 "translation missing: …"，
# 而且是**运行时**才发现。
ERRORS_NS = f"{NS}.errors"

# `errors.add(:attr, :key)` 走的是 ActiveRecord 自己的键空间。
AR_NS = "activerecord.errors.models"

# Rails 自带的内建校验消息。它们由 activemodel / activerecord 的 locale 文件
# 注册进 I18n.load_path（Railtie 的 initializer 做的），任何 Rails 应用都必然
# 存在，插件不需要、也不应该自己再定义一遍。Discourse 核心的 server.en.yml 里
# 连 `activerecord:` 这一层都没有，核心模型照样直接用 `errors.add(:x, :too_long)`。
#
# 集合逐个抄自源码，不是猜的：
#   activemodel/lib/active_model/locale/en.yml   → en.errors.messages.*
#   activerecord/lib/active_record/locale/en.yml → en.errors.messages.*
BUILTIN_AR_ERROR_KEYS = frozenset(
    {
        # ActiveModel
        "model_invalid", "inclusion", "exclusion", "invalid", "confirmation",
        "accepted", "empty", "blank", "present", "too_long", "password_too_long",
        "too_short", "wrong_length", "not_a_number", "not_an_integer",
        "greater_than", "greater_than_or_equal_to", "equal_to", "less_than",
        "less_than_or_equal_to", "other_than", "in", "odd", "even",
        # ActiveRecord
        "required", "taken",
    }
)


def check_server_i18n() -> None:
    keys = server_keys("en")

    ruby_files = (
        sources("plugin.rb")
        + sources("app/**/*.rb")
        + sources("lib/**/*.rb")
        + sources("db/**/*.rb")
    )

    for path in ruby_files:
        text = read(path)
        where = rel(path)

        for match in RUBY_I18N_LITERAL_RE.finditer(text):
            key = match.group("key")
            if not key.startswith(f"{NS}."):
                continue
            # `I18n.t("ticketing_system.#{ns}.#{name}")` 会被上面的正则整体吞掉
            # （`#{}` 里没有引号），交给下面那条分支。
            if "#{" in key:
                continue
            if key not in keys:
                line = text.count("\n", 0, match.start()) + 1
                error(where, f"第 {line} 行引用了不存在的服务端键 `{key}`")

        for match in RUBY_I18N_DYNAMIC_RE.finditer(text):
            body = match.group("body")
            if "#{" not in body:
                # 没有插值 → 普通字面量，上面那条分支已经查过。
                continue
            head = body.split("#{", 1)[0]
            if not head.startswith(f"{NS}."):
                continue
            prefix = head.rstrip(".")
            if len(prefix.split(".")) < 3:
                continue
            # 同客户端：不补那个点，因为拼出来的段常以 `_` 结尾。
            if not any(k.startswith(prefix) for k in keys):
                line = text.count("\n", 0, match.start()) + 1
                error(
                    where,
                    f"第 {line} 行动态拼出的键前缀 `{prefix}` 在 server.en.yml 里"
                    f"一个都不存在",
                )

        for match in ERRORS_NEW_RE.finditer(text):
            key = match.group("key")
            full = f"{ERRORS_NS}.{key}"
            if full not in keys:
                line = text.count("\n", 0, match.start()) + 1
                error(
                    where,
                    f"第 {line} 行 `Errors::…new(:{key})` 需要 server.en.yml 里有 "
                    f"`{full}`",
                )

    # errors.add 的检查按模型逐个做：ActiveRecord 把 `:unknown_group` 查成
    # `activerecord.errors.models.<model_key>.attributes.<attr>.unknown_group`，
    # 而 `<model_key>` 是 "ticketing_system/department" 这种带斜杠的形式
    # （模型的 i18n_key 含命名空间）。
    for path in sources("app/models/ticketing_system/*.rb"):
        text = read(path)
        where = rel(path)
        model = AR_CLASS_RE.search(text)
        if not model:
            continue
        model_key = f"{NS}/{path.stem}"
        for match in ERRORS_ADD_RE.finditer(text):
            attr, key = match.group("attr"), match.group("key")
            if key in BUILTIN_AR_ERROR_KEYS:
                # Rails 自带文案，查下去一定会命中 en.errors.messages.<key>，
                # 不需要插件再定义。
                continue
            full = f"{AR_NS}.{model_key}.attributes.{attr}.{key}"
            if full not in keys:
                line = text.count("\n", 0, match.start()) + 1
                error(
                    where,
                    f"第 {line} 行 `errors.add(:{attr}, :{key})` 需要 server.en.yml "
                    f"里有 `{full}`（也不是 Rails 内建键）",
                )


def check_error_classes() -> None:
    defined = set()
    errors_rb = ROOT / "lib/ticketing_system/errors.rb"
    if errors_rb.exists():
        for match in re.finditer(r"class\s+(\w+)\s*<", read(errors_rb)):
            defined.add(match.group(1))

    for path in sources("app/**/*.rb") + sources("lib/**/*.rb") + sources("plugin.rb"):
        text = read(path)
        for match in re.finditer(r"Errors::(\w+)", text):
            name = match.group(1)
            if name not in defined:
                line = text.count("\n", 0, match.start()) + 1
                error(rel(path), f"第 {line} 行引用了未定义的 Errors::{name}")


# ---------------------------------------------------------------------------
# L. Errors::* 的插值参数 ↔ ticketing_system.errors.* 的 %{} 占位符
# ---------------------------------------------------------------------------

# 子类不传 key 时用的默认值，抄自 lib/ticketing_system/errors.rb。
DEFAULT_ERROR_KEYS = {
    "Disabled": "disabled",
    "Forbidden": "forbidden",
    "NotFound": "not_found",
    "BadRequest": "bad_request",
}

# `Errors::Invalid.new(` / `Errors::Forbidden.new` —— 括号可有可无。
ERRORS_CALL_RE = re.compile(r"Errors::(?P<klass>\w+)\.new\b(?P<paren>\()?")
# 关键字参数。只认「行首或逗号之后」的名字，这样 `unknown.join(",")` 里的逗号
# 不会被当成参数分隔符。
ERRORS_KEYWORD_RE = re.compile(r"(?:^|,)\s*(?P<name>\w+):")
PLACEHOLDER_RE = re.compile(r"%\{(?P<name>\w+)\}")


def check_error_placeholders() -> None:
    """调用点传的插值参数必须和文案里的占位符一一对上。

    `Errors::Base#initialize` 把 `**options` 直接喂给 `I18n.t`，所以：

    * 文案里有 `%{x}` 而调用点没传 `x:` → 界面上出现
      `[missing %{x} value]`，只有真跑到那条分支才看得见；
    * 调用点传了 `x:` 而文案里没有 `%{x}` → 无害，但说明两边已经漂移了。

    前者是 ERROR，后者是 WARN —— 判断标准是「用户能不能看见」。
    """
    keys = server_keys("en")

    for path in sources("app/**/*.rb") + sources("lib/**/*.rb"):
        if path.name == "errors.rb":
            continue  # 那是定义处，不是调用处

        text = read(path)
        where = rel(path)

        for match in ERRORS_CALL_RE.finditer(text):
            klass = match.group("klass")

            if match.group("paren"):
                args = call_arguments(text, match.end() - 1)
                if args is None:
                    continue
                args = args.strip()
            else:
                args = ""

            # 第一个位置参数是 key；没有就用子类的默认值。
            # 非 `:symbol` 开头的参数说明 key 是动态算出来的
            # （`Forbidden.new(key)`），不猜。
            if args and not args.startswith(":"):
                continue

            key_match = re.match(r":(?P<key>\w+)", args)
            key = key_match.group("key") if key_match else DEFAULT_ERROR_KEYS.get(klass)
            if key is None:
                continue

            entry = keys.get(f"{ERRORS_NS}.{key}")
            if entry is None:
                continue  # 键本身不存在，check_server_i18n 已经报过

            # 复数化条目（one/other）的占位符可能只写在其中一个下面。
            texts = entry.values() if isinstance(entry, dict) else [entry]
            placeholders = {
                found.group("name")
                for value in texts
                for found in PLACEHOLDER_RE.finditer(str(value))
            }

            # `http_status:` 是 Base 自己的关键字，不进插值哈希。
            options = {
                found.group("name") for found in ERRORS_KEYWORD_RE.finditer(args)
            }
            options.discard("http_status")

            line = text.count("\n", 0, match.start()) + 1
            for name in sorted(placeholders - options):
                error(
                    where,
                    f"第 {line} 行 `Errors::{klass}.new(:{key})` 没有给 `{name}` 传值，"
                    f"`{ERRORS_NS}.{key}` 里的 `%{{{name}}}` 会渲染成 "
                    f"`[missing %{{{name}}} value]`",
                )
            for name in sorted(options - placeholders):
                warn(
                    where,
                    f"第 {line} 行 `Errors::{klass}.new(:{key})` 传了 `{name}:`，"
                    f"但 `{ERRORS_NS}.{key}` 的文案里没有 `%{{{name}}}`",
                )


# ---------------------------------------------------------------------------
# E / F. site_settings ↔ locale ↔ Ruby 用法
# ---------------------------------------------------------------------------


def settings_keys() -> set[str]:
    data = locales.get("config/settings.yml", {})
    return set((data.get("plugins") or {}).keys())


def check_settings_locales() -> None:
    keys = settings_keys()
    for locale in LOCALES:
        srv = server_keys(locale)
        for key in sorted(keys):
            if f"site_settings.{key}" not in srv:
                error(
                    f"config/locales/server.{locale}.yml",
                    f"缺少设置项说明 `site_settings.{key}`",
                )
        # 反向：有说明却没有设置项，通常意味着设置被改名后忘了改文案。
        for dotted in sorted(srv):
            if dotted.startswith("site_settings."):
                name = dotted[len("site_settings.") :]
                if name not in keys:
                    warn(
                        f"config/locales/server.{locale}.yml",
                        f"`{dotted}` 没有对应的设置项（是不是改名了？）",
                    )


def check_settings_usage() -> None:
    keys = settings_keys()
    pattern = re.compile(r"SiteSetting\.(ticketing_system_\w+)")

    for path in sources("app/**/*.rb") + sources("lib/**/*.rb") + sources("plugin.rb"):
        text = read(path)
        for match in pattern.finditer(text):
            name = match.group(1)
            if name not in keys:
                line = text.count("\n", 0, match.start()) + 1
                error(
                    rel(path),
                    f"第 {line} 行读了一个不存在的设置 `{name}`"
                    f"（会在运行时抛 NoMethodError）",
                )


# ---------------------------------------------------------------------------
# G. 常量枚举 ↔ 两边的文案
# ---------------------------------------------------------------------------


def ruby_constants() -> dict[str, list[str]]:
    """从 constants.rb 里抽出参与校验的枚举成员名。

    STATUSES / PRIORITIES 是哈希字面量，EVENT_KINDS 是 %w 数组 —— 两种形状都要
    认。只认哈希的话，EVENT_KINDS 会安静地不被检查，而「安静」正是这里要消灭的
    东西：`EventSerializer#kind_label` 用 `default: kind` 查文案，少一条只会退化
    成机器名，没有任何人会来报这个 bug。
    """
    path = ROOT / "lib/ticketing_system/constants.rb"
    if not path.exists():
        return {}

    text = read(path)
    out: dict[str, list[str]] = {}

    for name in ("STATUSES", "PRIORITIES"):
        match = re.search(
            rf"{name}\s*=\s*\{{(?P<body>.*?)\}}\s*\.freeze", text, re.DOTALL
        )
        if not match:
            match = re.search(rf"{name}\s*=\s*\{{(?P<body>.*?)\}}", text, re.DOTALL)
        if not match:
            warn("lib/ticketing_system/constants.rb", f"没能解析出 {name}")
            continue
        out[name] = re.findall(r"(\w+)\s*:", match.group("body"))

    array = re.search(
        r"EVENT_KINDS\s*=\s*%w\[(?P<body>.*?)\]\s*\.freeze", text, re.DOTALL
    )
    if not array:
        warn("lib/ticketing_system/constants.rb", "没能解析出 EVENT_KINDS")
    else:
        out["EVENT_KINDS"] = array.group("body").split()

    return out


def check_enums() -> None:
    constants = ruby_constants()

    # (常量名, 文案命名空间, 要查的文案文件, 缺文案时的降级表现)
    #
    # STATUSES / PRIORITIES 的值会作为键名送到客户端，两种语种的客户端文案里都
    # 得有。EVENT_KINDS 的标签是 `EventSerializer` 在服务端用 `I18n.t` 查的，只
    # 存在于 server.*.yml —— 去 client.*.yml 里找它只会凭空报假错。
    #
    # 最后一列不是修饰：枚举缺文案会渲染成原始键名，一眼就能看见；而 kind_label
    # 带 `default: kind`，缺文案只会安静地退化成机器名。后者才是静态检查真正要
    # 兜住的那一类，因为它不会有人来报 bug。
    mapping = (
        ("STATUSES", "status", ("client", "server"), "会渲染成原始键名"),
        ("PRIORITIES", "priority", ("client", "server"), "会渲染成原始键名"),
        ("EVENT_KINDS", "event", ("server",), "会静默降级成机器名"),
    )

    for const, namespace, sides, fallback in mapping:
        names = constants.get(const)
        if not names:
            continue

        for locale in LOCALES:
            for side in sides:
                if side == "client":
                    keys = client_keys(locale)
                    label = f"config/locales/client.{locale}.yml"
                else:
                    keys = server_keys(locale)
                    label = f"config/locales/server.{locale}.yml"

                for name in names:
                    full = f"{NS}.{namespace}.{name}"
                    if full not in keys:
                        error(
                            label,
                            f"`{const}` 里有 `{name}`，但缺少文案 `{full}`"
                            f"（{fallback}）",
                        )


# ---------------------------------------------------------------------------
# I. plugin.rb 元数据
# ---------------------------------------------------------------------------


def check_plugin_metadata() -> None:
    path = ROOT / "plugin.rb"
    if not path.exists():
        error("plugin.rb", "文件不存在")
        return

    text = read(path)

    name = None
    for line in text.splitlines():
        stripped = line.strip()
        # Plugin::Metadata#parse_line 对剥离后为纯 "#" 的行执行 nil.strip，
        # 抛 NoMethodError 中止整个 boot，且回溯指向核心、不报插件名。
        if stripped == "#":
            error(
                "plugin.rb",
                "有一行的剥离内容是纯 `#`：会让 Plugin::Metadata#parse_line 抛 "
                "NoMethodError 并中止启动",
            )
        if stripped.startswith("# name:"):
            name = stripped.split(":", 1)[1].strip()

    if name is None:
        error("plugin.rb", "缺少 `# name:` 元数据行")
    elif name != PLUGIN_DIR_NAME:
        error(
            "plugin.rb",
            f"`# name: {name}` 与目录名 `{PLUGIN_DIR_NAME}` 不一致；"
            f"核心的样式表路由把 name 约束为小写",
        )

    declared = re.search(r'PLUGIN_NAME\s*=\s*"([^"]+)"', text)
    if not declared:
        error("plugin.rb", "没有定义 PLUGIN_NAME")
    elif declared.group(1) != PLUGIN_DIR_NAME:
        error(
            "plugin.rb",
            f"PLUGIN_NAME = {declared.group(1)!r} 与目录名不一致",
        )


# ---------------------------------------------------------------------------
# J. 前端 API 路径 ↔ config/routes.rb
# ---------------------------------------------------------------------------

API_NAME_RE = re.compile(r"\bapi\s*\(")
ROUTE_RE = re.compile(
    r"""^\s*(?:get|post|put|patch|delete)\s+"(?P<path>/[^"]*)"\s*=>""", re.MULTILINE
)
# 一个调用参数：双引号串 / 单引号串 / 反引号模板 / 其它表达式。
# 反引号要单独认出来，否则 `` `${x}` `` 里的逗号会把参数切错。
API_ARG_RE = re.compile(
    r"""(?P<dq>"[^"]*")|(?P<sq>'[^']*')|(?P<bq>`[^`]*`)|(?P<raw>[^,]+)"""
)


def call_arguments(text: str, open_paren: int) -> str | None:
    """返回 `open_paren` 处那个 `(` 与配对 `)` 之间的内容。

    不能用 `[^)]*` 偷懒：`api("tickets", String(this.ticket.id))` 会在第一个
    `)` 处截断，参数段于是变成一整块表达式 `String(this.ticket.id`，路径自然
    对不上，报出一条不存在的 404。这里按括号深度扫，并跳过字符串里的括号。
    """
    depth = 0
    quote: str | None = None
    index = open_paren
    while index < len(text):
        char = text[index]
        if quote:
            if char == "\\":
                index += 2
                continue
            if char == quote:
                quote = None
        elif char in "\"'`":
            quote = char
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return text[open_paren + 1 : index]
        index += 1
    return None


def check_api_paths() -> None:
    routes_path = ROOT / "config/routes.rb"
    if not routes_path.exists():
        return

    text = read(routes_path)
    # 只取 `scope "/api"` 块里的那批路由。
    api_block = text.split('scope "/api"', 1)
    if len(api_block) < 2:
        error("config/routes.rb", "没有找到 `scope \"/api\"` 块")
        return
    api_block = api_block[1].split("\n  end", 1)[0]

    known: set[str] = set()
    for match in ROUTE_RE.finditer(api_block):
        # "/tickets/:id" → "tickets/:id"
        known.add(match.group("path").strip("/"))

    for path in sources("assets/javascripts/**/*.js") + sources(
        "assets/javascripts/**/*.gjs"
    ):
        text = read(path)
        for match in API_NAME_RE.finditer(text):
            # `function api(...segments) { … }` 是辅助函数的定义，不是调用。
            # 它的参数是 rest 参数，第一段必然是 `...segments`，不排掉就必然误报。
            if re.search(r"function\s+$", text[: match.start()]):
                continue

            args = call_arguments(text, match.end() - 1)
            if args is None:
                continue
            args = args.strip()
            if not args or args.startswith("..."):
                continue

            segments: list[str] = []
            dynamic = False
            for arg in API_ARG_RE.finditer(args):
                literal = arg.group("dq") or arg.group("sq") or arg.group("bq")
                if literal is None:
                    # 非字面量（`String(this.draft.id)`、`params.id`）→ 一个参数段。
                    dynamic = True
                    segments.append(":id")
                    continue
                literal = literal[1:-1]  # 去掉引号
                if "${" in literal:
                    # `` `${id}` `` 是插值，同样当参数段。
                    dynamic = True
                    segments.append(":id")
                else:
                    segments.append(literal)

            if not segments:
                continue

            candidate = "/".join(segments)
            if candidate in known:
                continue
            if dynamic and any(k.split("/")[0] == segments[0] for k in known):
                # 带参数的路径只校验第一段，避免把 `tickets/:id` 这种
                # 段数不固定的情况误报。
                continue

            line = text.count("\n", 0, match.start()) + 1
            error(
                rel(path),
                f"第 {line} 行调用 api({args}) → `/{candidate}`，"
                f"config/routes.rb 里没有这条路由（会 404）",
            )


# ---------------------------------------------------------------------------
# K. 前端相对导入必须可达
# ---------------------------------------------------------------------------


def check_relative_imports() -> None:
    pattern = re.compile(r"""from\s+["'](?P<path>\.{1,2}/[^"']+)["']""")
    suffixes = ("", ".js", ".gjs", ".mjs", "/index.js", "/index.gjs")

    for path in sources("assets/javascripts/**/*.js") + sources(
        "assets/javascripts/**/*.gjs"
    ):
        text = read(path)
        for match in pattern.finditer(text):
            target = match.group("path")
            base = (path.parent / target).resolve()
            if any(Path(str(base) + suffix).exists() for suffix in suffixes):
                continue
            line = text.count("\n", 0, match.start()) + 1
            error(rel(path), f"第 {line} 行的相对导入 `{target}` 解析不到文件")


# ---------------------------------------------------------------------------
# J. 已提交的迁移不得修改
# ---------------------------------------------------------------------------


def check_migrations_are_append_only() -> None:
    """迁移只增不改 —— 已经提交过的迁移再动一下，就是一个不会报错的故障。

    这个检查是一次真实故障留下的。有人把「工单上的两个共享未读计数器」换成
    「每人一行的读标记」时，直接改了已经发布、而且已经在用户的库里跑过的
    `20261006000002`，没有新加迁移。

    Rails 把跑过的迁移记在 `schema_migrations` 里，**永远不会重跑它**。于是
    改动只对「之后才安装的库」生效，已跑过它的库纹丝不动：新代码要的三个列
    在既有库里根本不存在，一读就是 Postgres 的 undefined column / NoMethodError，
    而报错指向查询、不指向「列没建」—— 排查方向一开始就是错的。

    这类 bug 读代码发现不了，两边各自看都是对的，只有把「库是怎么来的」和
    「代码要什么」放在一起才看得出来。所以它只能靠一条机械规则拦住。

    比的是工作区与 HEAD 的差异。因此改动一旦被单独提交，检查自动变绿 —— 这
    不是留了个后门，而是这个检查要的正是「这次修改必须是有意为之、且能被单独
    看见」，而不是夹带在别的改动里。

    新增迁移不受影响：`git diff` 不列未跟踪文件，已 `git add` 的新文件是 A，
    也被 `--diff-filter=MDR` 排除在外。
    """
    if shutil.which("git") is None:
        warn("db/migrate", "PATH 里没有 git：跳过「已提交的迁移不得修改」检查")
        return

    diff = subprocess.run(
        [
            "git",
            "-C",
            str(ROOT),
            "diff",
            "HEAD",
            "--name-only",
            "--diff-filter=MDR",
            "--",
            "db/migrate",
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )

    # 没有提交历史（tarball、刚 init 的仓库）时 git diff HEAD 会失败，
    # 那是环境问题，不是代码问题。
    if diff.returncode != 0:
        warn("db/migrate", "git diff 不可用：跳过「已提交的迁移不得修改」检查")
        return

    for path in diff.stdout.splitlines():
        path = path.strip()
        if not path:
            continue
        error(
            path,
            "已提交的迁移被修改了。迁移只增不改：Rails 不会重跑它，改动只对"
            "之后安装的库生效，已有库会与代码永久分叉。请新加一个迁移",
        )


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verbose", action="store_true", help="同时打印通过的项目")
    args = parser.parse_args()

    checks = [
        ("YAML 可解析 / 客户端 js: 包装", check_yaml),
        ("两个语种的键集对齐", check_locale_parity),
        ("前端 i18n 调用 → client.en.yml", check_client_i18n),
        ("服务端 i18n / Errors / errors.add → server.en.yml", check_server_i18n),
        ("Errors::* 类名存在", check_error_classes),
        ("Errors::* 插值参数 ↔ 文案占位符", check_error_placeholders),
        ("site_settings ↔ 文案", check_settings_locales),
        ("site_settings ↔ Ruby 用法", check_settings_usage),
        ("枚举（状态 / 优先级 / 事件种类）↔ 文案", check_enums),
        ("plugin.rb 元数据", check_plugin_metadata),
        ("前端 API 路径 ↔ config/routes.rb", check_api_paths),
        ("前端相对导入可达", check_relative_imports),
        ("已提交的迁移未被修改", check_migrations_are_append_only),
    ]

    passed: list[str] = []
    for label, check in checks:
        before = len(findings)
        check()
        if len(findings) == before:
            passed.append(label)

    errors = [f for f in findings if f[0] == SEVERITY_ERROR]
    warnings = [f for f in findings if f[0] == SEVERITY_WARN]

    if args.verbose:
        print("通过：")
        for label in passed:
            print(f"  ✓ {label}")
        print()

    for severity, where, message in errors + warnings:
        print(f"{severity:<5} {where}: {message}")

    if errors or warnings:
        print()

    print(
        f"共 {len(errors)} 个错误，{len(warnings)} 个警告"
        f"（{len(checks)} 项检查，{len(passed)} 项通过）"
    )

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
