#!/usr/bin/env sh
#
# 提交之前跑这一条。
#
# 四个阶段，任何一个失败就立刻停：
#
#   1/4  前端模板作用域 + JS 语法        scripts/check-templates.py
#   2/4  跨文件静态一致性                scripts/validate.py
#   3/4  Ruby 语法 + ERB 可编译          ruby -c / ERB#src
#   4/4  变异自测                        scripts/selftest.py
#
# 阶段 3 在没装 ruby 的机器上会跳过并打印一行说明；1、2、4 必须跑。
# 阶段 4 是唯一一个能证明 1、2 没有空转的检查 —— 它向代码里注入 14 处缺陷，
# 确认校验器确实报错，然后把文件恢复原样。
#
# 用法：
#   sh scripts/selftest.sh
#   PYTHON=/c/Python314/python.exe sh scripts/selftest.sh

set -eu

cd "$(dirname "$0")/.."

step() {
  printf '\n=== %s ===\n' "$1"
}

step "1/4 前端模板作用域与 JS 语法"
sh scripts/py.sh scripts/check-templates.py --verbose

step "2/4 跨文件静态一致性"
sh scripts/py.sh scripts/validate.py --verbose

step "3/4 Ruby 语法与 ERB"
if command -v ruby >/dev/null 2>&1; then
  # 逻辑放在 scripts/check-ruby.rb 里，不用 heredoc：Windows 上 Ruby 从 stdin
  # 读脚本会按外部编码（GBK）解码，脚本里任何非 ASCII 字符都会报
  # `invalid multibyte char` —— 看起来像语法错误，其实只是编码。
  ruby scripts/check-ruby.rb
else
  echo "跳过：PATH 里没有 ruby。装了之后再跑，这一层能抓到 .rb 与 .erb 的语法错。"
fi

step "4/4 变异自测"
sh scripts/py.sh scripts/selftest.py

printf '\n=== 全部通过 ===\n'
