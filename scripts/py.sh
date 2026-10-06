#!/usr/bin/env sh
#
# 找到可用的 Python 3 并执行它。
#
# 存在的理由：Windows 上解释器叫 `python`，Linux/CI 上叫 `python3`。把任何一个
# 写死在 npm scripts 或 selftest.sh 里，都会在另一边上以「command not found」
# 挂掉 —— 而那种失败看起来像是校验器本身有问题。
#
# 用法：
#   sh scripts/py.sh scripts/validate.py --verbose
#   PYTHON=/c/Python314/python.exe sh scripts/py.sh scripts/validate.py

set -eu

for candidate in "${PYTHON:-}" python3 python py; do
  [ -n "$candidate" ] || continue
  command -v "$candidate" >/dev/null 2>&1 || continue
  # 版本必须 >= 3.9：脚本里用了 `list[str]` 这种内置泛型注解。
  if "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' >/dev/null 2>&1; then
    exec "$candidate" "$@"
  fi
done

echo "找不到 Python 3.9+。用 PYTHON=/path/to/python 指定解释器。" >&2
exit 1
