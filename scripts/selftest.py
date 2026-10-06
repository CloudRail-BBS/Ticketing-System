#!/usr/bin/env python3
"""变异自测：证明两个静态校验器不是空转的。

一个从不报错的校验器和一个不存在的校验器，效果完全一样。这个脚本对每一项
检查各注入一处「只有真的查了才会发现」的缺陷，跑一遍校验器，确认它确实以
非零退出码报出预期的那句话，然后**把文件恢复原样**。

先跑基线：基线必须全绿。否则「注入后变红」什么也证明不了 —— 一个一直红着的
校验器同样抓不住任何东西。

用法：
    python scripts/selftest.py

依赖：无（除标准库）。它调用的两个校验器自己会处理各自的依赖。
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PYTHON = sys.executable

VALIDATE = "scripts/validate.py"
TEMPLATES = "scripts/check-templates.py"
RUBY = "scripts/check-ruby.rb"


@dataclass
class Mutation:
    what: str  # 注入的是什么缺陷
    script: str  # 用哪个校验器抓
    expect: str  # 校验器输出里必须出现的一句话
    target: str  # 相对仓库根的路径
    old: str | None = None  # 就地替换：被替换掉的原文
    new: str = ""  # 就地替换：替换成什么（空串 = 删除）
    append: str | None = None  # 追加到文件末尾的内容
    create: bool = False  # target 是新建文件（跑完删掉）


# 每一条都对应 validate.py / check-templates.py 里的一个检查项。
# 用「追加」而不是「改一行」是有意的：追加不会和文件里已有内容打架，
# 恢复时也只需写回原字节。
MUTATIONS: list[Mutation] = [
    Mutation(
        what="客户端少一个键（en 有、zh_CN 没有）",
        script=VALIDATE,
        expect="缺少键",
        target="config/locales/server.en.yml",
        # 2 空格缩进 → 落在 `en:` 下面，与 `site_settings:` 同级。
        append='\n  selftest_probe:\n    only_in_en: "probe"\n',
    ),
    Mutation(
        what="前端 i18n 引用了不存在的键",
        script=VALIDATE,
        expect="引用了不存在的客户端键",
        target="assets/javascripts/discourse/lib/ticketing-system.js",
        append=(
            "\n// selftest\nexport function selftestProbe() {\n"
            '  return i18n("ticketing_system.selftest_probe_missing");\n}\n'
        ),
    ),
    Mutation(
        what="服务端 I18n.t 引用了不存在的键",
        script=VALIDATE,
        expect="引用了不存在的服务端键",
        target="lib/ticketing_system/version.rb",
        append=(
            "\nmodule ::TicketingSystem\n  module SelfTestI18nProbe\n"
            "    def self.label\n"
            '      I18n.t("ticketing_system.selftest_probe_missing")\n'
            "    end\n  end\nend\n"
        ),
    ),
    Mutation(
        what="引用了未定义的 Errors 子类",
        script=VALIDATE,
        expect="引用了未定义的 Errors::",
        target="lib/ticketing_system/version.rb",
        append=(
            "\nmodule ::TicketingSystem\n  module SelfTestErrorProbe\n"
            "    def self.build\n"
            "      Errors::SelfTestProbe.new(:probe)\n"
            "    end\n  end\nend\n"
        ),
    ),
    Mutation(
        what="读了一个不存在的 site_setting",
        script=VALIDATE,
        expect="读了一个不存在的设置",
        target="lib/ticketing_system/version.rb",
        append=(
            "\nmodule ::TicketingSystem\n  module SelfTestSettingProbe\n"
            "    def self.limit\n"
            "      SiteSetting.ticketing_system_selftest_missing\n"
            "    end\n  end\nend\n"
        ),
    ),
    Mutation(
        what="plugin.rb 出现剥离后为纯 # 的行",
        script=VALIDATE,
        expect="纯 `#`",
        target="plugin.rb",
        append="\n#\n",
    ),
    Mutation(
        what="前端 API 路径拼错",
        script=VALIDATE,
        expect="没有这条路由",
        target="assets/javascripts/discourse/lib/ticketing-system.js",
        append=(
            "\n// selftest\nexport const selftestProbe = "
            '() => api("selftest_missing_endpoint");\n'
        ),
    ),
    Mutation(
        what="相对导入解析不到文件",
        script=VALIDATE,
        expect="解析不到文件",
        target="assets/javascripts/discourse/lib/ticketing-system.js",
        append=(
            "\n// selftest\nexport { default as selftestProbe } "
            'from "./selftest-probe-missing";\n'
        ),
    ),
    Mutation(
        what="客户端 locale 少了 js: 包装",
        script=VALIDATE,
        expect="缺少 `js:` 包装",
        target="config/locales/client.en.yml",
        old="en:\n  js:\n",
        new="en:\n  jsx:\n",
    ),
    Mutation(
        what="模板里用了未 import 的辅助函数",
        script=TEMPLATES,
        expect="使用了未 import 的名字",
        target=(
            "assets/javascripts/discourse/components/ticketing-system/"
            "selftest-probe.gjs"
        ),
        create=True,
        append="export default <template>\n  {{not this.anything}}\n</template>;\n",
    ),
    Mutation(
        what="Errors 的插值参数与文案占位符对不上",
        script=VALIDATE,
        expect="[missing %{",
        target="lib/ticketing_system/version.rb",
        append=(
            "\nmodule ::TicketingSystem\n  module SelfTestPlaceholderProbe\n"
            "    def self.build\n"
            # 这个 key 的文案里有 %{status}，但不传 status: —— 界面上会出现
            # `[missing %{status} value]`，而且只在真跑到这条分支时看得见。
            "      Errors::Forbidden.new(:status_change_not_allowed_to)\n"
            "    end\n  end\nend\n"
        ),
    ),
    Mutation(
        what="Ruby 哈希里同一个键写了两遍（后者静默覆盖前者）",
        script=RUBY,
        expect="is duplicated",
        target="lib/ticketing_system/version.rb",
        append=(
            "\nmodule ::TicketingSystem\n  module SelfTestDuplicateKeyProbe\n"
            "    def self.options\n"
            '      { status: 400, status: "bogus" }\n'
            "    end\n  end\nend\n"
        ),
    ),
    Mutation(
        what="EVENT_KINDS 加了成员但没加文案（时间线会显示机器名）",
        script=VALIDATE,
        expect="会静默降级成机器名",
        target="lib/ticketing_system/constants.rb",
        # 往 %w 数组里塞一个新成员，而不是去 server.*.yml 里删一行：删文案会同时
        # 触发「两个语种的键集对齐」检查，那样即使枚举检查是空转的，这一项也照样
        # 变红 —— 就证明不了枚举检查本身有没有在工作了。
        old="      auto_closed\n    ].freeze",
        new="      auto_closed\n      selftest_probe\n    ].freeze",
    ),
    Mutation(
        what="已提交的迁移被原地修改（Rails 不会重跑，旧库拿不到新列）",
        script=VALIDATE,
        expect="迁移只增不改",
        target="db/migrate/20261006000003_create_ticketing_system_messages.rb",
        # 追加而不是改一行：追加不需要猜文件里已有的内容，恢复时也只需写回原字节。
        # 内容不重要 —— 这条检查比的是「工作区与 HEAD 的差异」，改一个注释也算改。
        append="\n# selftest probe\n",
    ),
]


def has_ruby() -> bool:
    return shutil.which("ruby") is not None


def write_text(path: Path, text: str) -> None:
    """以 LF 写文件，和 .gitattributes 里的 `eol=lf` 保持一致。

    `Path.write_text()` 在 Windows 上会把 `\\n` 翻成 `\\r\\n`（文本模式的通用换行
    转换）。注入缺陷时这不会造成错误的结果，但会让「变异前后只差一处」这个前提
    不成立 —— 校验器读到的每一行都多了一个 CR，而 .gjs / .yml 的解析对行尾是敏感的。
    显式指定 newline 就不必依赖 `Path.write_text(newline=...)`（Python 3.10 才有）。
    """
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


def run(script: str) -> tuple[int, str]:
    # 用哪个解释器由脚本自己决定，不是由调用者决定 —— 三个校验器分属两种语言。
    interpreter = "ruby" if script.endswith(".rb") else PYTHON
    proc = subprocess.run(
        [interpreter, str(ROOT / script)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def main() -> int:
    ruby = has_ruby()
    if not ruby:
        print("PATH 里没有 ruby：跳过依赖它的基线与变异（其余照跑）。\n")

    baseline = [VALIDATE, TEMPLATES] + ([RUBY] if ruby else [])
    mutations = [m for m in MUTATIONS if ruby or m.script != RUBY]

    print("基线（必须全绿，否则后面变红没有意义）：")
    for script in baseline:
        code, out = run(script)
        if code != 0:
            print(f"  FAIL  {script}")
            print(out.rstrip())
            print("\n基线不通过，先修好再来跑变异自测。")
            return 1
        print(f"  OK    {script}")

    print(f"\n逐项注入缺陷（共 {len(mutations)} 项）：")
    missed = 0

    for index, mutation in enumerate(mutations, start=1):
        path = ROOT / mutation.target
        original = None if mutation.create else path.read_bytes()
        code = -1
        out = ""

        try:
            if mutation.create:
                write_text(path, mutation.append or "")
            elif mutation.append is not None:
                with path.open("ab") as handle:
                    handle.write(mutation.append.encode("utf-8"))
            else:
                text = path.read_text(encoding="utf-8")
                if mutation.old is None or mutation.old not in text:
                    raise AssertionError(f"锚点没找到：{mutation.old!r}")
                write_text(path, text.replace(mutation.old, mutation.new, 1))

            code, out = run(mutation.script)
            caught = code != 0 and mutation.expect in out
        finally:
            # 无论成功失败都要恢复，否则一次失败的变异会把仓库留在坏状态。
            if mutation.create:
                path.unlink(missing_ok=True)
            elif original is not None:
                path.write_bytes(original)

        if caught:
            print(f"  OK    #{index:<2} {mutation.what}")
            continue

        missed += 1
        print(f"  MISS  #{index:<2} {mutation.what}")
        print(
            f"        期望 {mutation.script} 报出 {mutation.expect!r}，"
            f"实际退出码 {code}"
        )
        body = out.strip()
        if body:
            for line in body.splitlines()[:12]:
                print(f"        | {line}")

    print()
    if missed:
        print(f"{missed} 项缺陷没被抓住 —— 对应的检查是空转的，去修校验器。")
        return 1

    print(f"{len(mutations)} 项缺陷全部被抓住，三个校验器都不是空转的。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
