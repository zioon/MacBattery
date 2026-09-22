#!/usr/bin/env python3
"""CI 守护：界面层不得残留硬编码文案。

规则：去掉注释后，`Sources/MacBattery/**` 与 `Sources/MacBatteryCore/**` 里任何
**含 CJK 字符的字符串字面量**都算硬编码文案，必须改写成 `L("key")` 并从
`Resources/<lang>.lproj/Localizable.strings` 取值。

为什么必须靠机器拦：`Text("中文")` 的字面量会走 `LocalizedStringKey` → `Bundle.main`，
**绕过应用内的语言选择**，表现是「切了语言，这一处不变」。这种漏网在界面上极难发现，
人肉 review 一定会漏。

豁免项（各有明确理由）：
  * `Sources/MacBatteryCore/Resources/**` —— 资源文件本身就是文案载体；
  * 日志调用所在行（`logger.error(...)` / `os_log(...)` 等）—— os_log 文案**刻意不本地化**：
    日志面向问题排查，本地化后同一条故障在不同语言下文本不同、无法 grep、也不好对照 issue；
  * 注释，含 `///` 文档注释与 `/* */` 块注释。

用法：在仓库根目录执行 `python3 Scripts/check_hardcoded_strings.py`（退出码 1 = 有违规）。
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCAN_ROOTS = [ROOT / "Sources" / "MacBattery", ROOT / "Sources" / "MacBatteryCore"]
SKIP_DIR_PARTS = {"Resources"}

CJK = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]")
# 日志调用行：这些行里的中文是有意保留的（见文件头说明）。
LOGGING_CALL = re.compile(
    r"\b(logger|Logger|os_log)\b[^\n]*\.(error|warning|notice|info|debug|trace|fault|log)\s*\("
)


def collect_literals(source):
    """扫描源码，返回 [(起始行号, 字面量内容)]，跳过全部注释。

    只处理普通字符串与 Swift 多行字符串；本项目未使用 raw string（`#"..."#`）。
    """
    literals = []
    index, length, line = 0, len(source), 1
    state = "code"
    buf = []
    start_line = 1

    while index < length:
        char = source[index]

        if state == "code":
            if source.startswith("//", index):
                state = "line_comment"
                index += 2
                continue
            if source.startswith("/*", index):
                state = "block_comment"
                index += 2
                continue
            if source.startswith('"""', index):
                state = "multiline"
                buf = []
                start_line = line
                index += 3
                continue
            if char == '"':
                state = "string"
                buf = []
                start_line = line
                index += 1
                continue
            if char == "\n":
                line += 1
            index += 1
            continue

        if state == "line_comment":
            if char == "\n":
                state = "code"
                line += 1
            index += 1
            continue

        if state == "block_comment":
            if source.startswith("*/", index):
                state = "code"
                index += 2
                continue
            if char == "\n":
                line += 1
            index += 1
            continue

        if state == "string":
            if char == "\\":
                buf.append(source[index:index + 2])
                index += 2
                continue
            if char == '"':
                literals.append((start_line, "".join(buf)))
                state = "code"
                index += 1
                continue
            if char == "\n":
                line += 1
            buf.append(char)
            index += 1
            continue

        # state == "multiline"
        if source.startswith('"""', index):
            literals.append((start_line, "".join(buf)))
            state = "code"
            index += 3
            continue
        if char == "\n":
            line += 1
        buf.append(char)
        index += 1

    return literals


def swift_files():
    for root in SCAN_ROOTS:
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*.swift")):
            if SKIP_DIR_PARTS & set(path.relative_to(ROOT).parts):
                continue
            yield path


def main():
    violations = []
    scanned = 0

    for path in swift_files():
        scanned += 1
        source = path.read_text(encoding="utf-8")
        lines = source.splitlines()
        for line_number, literal in collect_literals(source):
            if not CJK.search(literal):
                continue
            raw_line = lines[line_number - 1] if 0 < line_number <= len(lines) else ""
            if LOGGING_CALL.search(raw_line):
                continue
            violations.append((path.relative_to(ROOT), line_number, literal.strip()))

    if violations:
        print("::error::发现硬编码文案，请改用 L(\"key\") 并从 .lproj/Localizable.strings 取值")
        print("（若确实是刻意不本地化的日志文案，请加在 logger.error(...) 等调用里）\n")
        for path, line_number, literal in violations:
            print(f"{path}:{line_number}: {literal}")
        print(f"\n共 {len(violations)} 处违规，扫描 {scanned} 个 Swift 文件。")
        return 1

    print(f"OK：{scanned} 个 Swift 文件均无硬编码文案。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
