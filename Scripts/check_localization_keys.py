#!/usr/bin/env python3
"""CI 守护：语言资源与调用点的一致性。

覆盖三类问题，都是「编译能过、单测也未必发现、但用户能看见」的：

1. **键名不一致**：某语言缺键（漏翻译）。运行时虽会回退到默认语言，但漏翻会悄悄变成
   长期债务，所以直接在 CI 拦掉。允许 `en` 多出复数单数形 `<key>.one`。
2. **格式占位符漂移**：同一键在不同语言里的 `%@` / `%d` 数量或类型不同 —— 译文漏掉一个参数时
   `String(format:)` 会输出垃圾或空串，这类错误靠人眼校对几乎必漏。
3. **调用点引用了不存在的键**：代码里写 `L("...")` 却忘了在默认语言里加条目。
   运行时表现是界面上直接显示键名，属于「上线才发现」的问题。
   注意：只能静态推导字面量键；动态键（如 `L(preset.localizationKey)`）不在本脚本覆盖范围，
   由 `LocalizationTests` 与人工审查兜底。

用法：在仓库根目录执行 `python3 Scripts/check_localization_keys.py`（退出码 1 = 有违规）。
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Sources" / "MacBatteryCore" / "Resources"
SWIFT_ROOTS = [ROOT / "Sources" / "MacBattery", ROOT / "Sources" / "MacBatteryCore"]
DEFAULT_LANGUAGE = "zh-Hans"

ENTRY = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')
# 只取完全字面量的键：含 \( 插值的键（如 L("language.\(rawValue)")）无法静态推导。
CALL = re.compile(r'\bL{1,2}\("([^"\\]+)"')
SPECIFIER = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?[a-zA-Z@]")


def parse_strings(path):
    text = path.read_text(encoding="utf-8")
    return {key: value for key, value in ENTRY.findall(strip_comments(text))}


def strip_comments(text):
    """去掉注释。

    刻意保持简单（正则）：这里只用于「抽取键」，误伤的后果是漏报某一行而不是误报。
    已知局限：字符串字面量里出现 `//`（如 URL）会截断该行余下内容，故不在本文件的
    扫描目标内 —— 真正的硬编码文案拦截由 check_hardcoded_strings.py 用状态机完成。
    """
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"(?m)//.*$", "", text)


def specifiers(value):
    # 忽略 %% 这个转义后的字面百分号。
    return sorted(m.group(0) for m in SPECIFIER.finditer(value))


def swift_files():
    for root in SWIFT_ROOTS:
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*.swift")):
            yield path


def main():
    problems = []

    tables = {}
    for path in sorted(RESOURCES.glob("*.lproj/Localizable.strings")):
        # 目录名形如 zh-Hans.lproj → 语言标识取 stem。
        language = path.parent.stem
        tables[language] = parse_strings(path)

    if DEFAULT_LANGUAGE not in tables:
        print(f"::error::找不到默认语言资源 {DEFAULT_LANGUAGE}.lproj/Localizable.strings")
        return 1

    default = tables[DEFAULT_LANGUAGE]
    print(f"默认语言 {DEFAULT_LANGUAGE}：{len(default)} 条文案")

    # 1. 键名一致性 + 2. 占位符一致性
    for language, table in sorted(tables.items()):
        if language == DEFAULT_LANGUAGE:
            continue
        missing = sorted(set(default) - set(table))
        if missing:
            problems.append(f"[{language}] 缺少 {len(missing)} 个键（漏翻译）：{missing}")

        allowed_extra = {
            key[: -len(".other")] + ".one" for key in default if key.endswith(".other")
        }
        extra = sorted(set(table) - set(default) - allowed_extra)
        if extra:
            problems.append(f"[{language}] 存在多余的键（键名拼写不一致？）：{extra}")

        drift = [
            f"{key}: {specifiers(default[key])} vs {specifiers(table[key])}"
            for key in sorted(set(default) & set(table))
            if specifiers(default[key]) != specifiers(table[key])
        ]
        if drift:
            problems.append(f"[{language}] 格式占位符与默认语言不一致：{drift}")

    # 3. 调用点引用的键必须存在
    referenced = set()
    for path in swift_files():
        source = strip_comments(path.read_text(encoding="utf-8"))
        for key in CALL.findall(source):
            referenced.add((key, path.relative_to(ROOT)))

    dangling = sorted({f"{key}（{path}）" for key, path in referenced if key not in default})
    if dangling:
        problems.append(f"代码引用了默认语言里不存在的 {len(dangling)} 个键：{dangling}")

    # 4. 复数键必须成对：只有 .one 没有 .other 时，其它数量会回退到键名本身。
    for language, table in sorted(tables.items()):
        orphan = sorted(
            key for key in table
            if key.endswith(".one") and key[: -len(".one")] + ".other" not in table
        )
        if orphan:
            problems.append(f"[{language}] 有 .one 却没有对应的 .other：{orphan}")

    if problems:
        print("::error::语言资源与调用点不一致")
        for problem in problems:
            print(f"\n{problem}")
        return 1

    print(f"OK：{len(referenced)} 处字面量键全部存在；各语言键名与占位符一致。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
