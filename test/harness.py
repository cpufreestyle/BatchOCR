#!/usr/bin/env python3
"""
BatchOCR 契约 harness —— 对照 docs/SPEC.md 逐条验证。

用法：
    python3 test/harness.py            # 全部检查
    python3 test/harness.py --fast     # 跳过 OCR 识别段（只跑静态 + CLI 契约）

退出码：0 全部通过；1 存在失败。

设计原则：
- 只依赖标准库与已构建产物（build/BatchOCR.app、build/sample_tool）。
- 每条断言标注其对应的 SPEC 编号，失败时能直接定位契约。
- 不调用 GUI；GUI 不变量（S-30..S-35）以静态源码检查（F 段）覆盖可自动化的部分。
"""

import argparse
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "build", "BatchOCR.app")
CLI = os.path.join(APP, "Contents", "MacOS", "BatchOCR")
TOOL = os.path.join(ROOT, "build", "sample_tool")
MAIN = os.path.join(ROOT, "Sources", "main.swift")
PLIST = os.path.join(ROOT, "resources", "Info.plist")
SPEC = os.path.join(ROOT, "docs", "SPEC.md")

PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"
results = []  # (status, spec_id, name, detail)


def record(status, spec_id, name, detail=""):
    results.append((status, spec_id, name, detail))
    mark = {PASS: "✅", FAIL: "❌", SKIP: "⏭️"}[status]
    line = f"  {mark} [{spec_id}] {name}"
    if detail and status != PASS:
        line += f"\n        → {detail}"
    print(line, flush=True)


def check(spec_id, name, cond, detail=""):
    record(PASS if cond else FAIL, spec_id, name, detail)
    return bool(cond)


def run(args, timeout=300, cwd=None):
    t0 = time.time()
    p = subprocess.run(args, capture_output=True, text=True, timeout=timeout, cwd=cwd)
    return p.returncode, p.stdout, p.stderr, time.time() - t0


def cli(*args, timeout=300, cwd=None):
    return run([CLI, "--cli", *args], timeout=timeout, cwd=cwd)


def must_exist(path):
    if not os.path.exists(path):
        print(f"缺少构建产物：{path}\n请先运行 ./build.sh", file=sys.stderr)
        sys.exit(2)


# ---------------------------------------------------------------- A. 产物/版本
def section_a():
    print("\nA. 版本与产物")
    check("S-02", "CLI 可执行文件存在", os.path.isfile(CLI), CLI)

    rc, out, err, _ = cli("--version")
    m = re.match(r"^BatchOCR (\d+\.\d+\.\d+)$", out.strip())
    check("S-02", "--version 输出格式", rc == 0 and bool(m), f"rc={rc} out={out.strip()!r}")
    code_ver = m.group(1) if m else None

    with open(PLIST, "rb") as f:
        pl = plistlib.load(f)
    plist_ver = pl.get("CFBundleShortVersionString")
    check("S-01", "版本号：代码 == Info.plist",
          code_ver is not None and code_ver == plist_ver,
          f"code={code_ver} plist={plist_ver}")

    check("S-03", "LSMinimumSystemVersion = 14.0", pl.get("LSMinimumSystemVersion") == "14.0",
          str(pl.get("LSMinimumSystemVersion")))
    doc_types = pl.get("CFBundleDocumentTypes") or []
    flat = [t for d in doc_types for t in (d.get("LSItemContentTypes") or [])]
    check("S-03", "声明 PDF 与图片文档类型",
          "com.adobe.pdf" in flat and any(x in flat for x in ("public.png", "public.jpeg", "public.tiff")),
          str(flat))


# ------------------------------------------------------------- F. 源码不变量
def section_f():
    print("\nF. GUI 源码不变量")
    src = open(MAIN, encoding="utf-8").read()
    check("S-30", "flipped 坐标 + 手动布局（无 NSStackView）",
          "var isFlipped: Bool { true }" in src and "layoutContent" in src and "NSStackView" not in src,
          "需保留 flipped DropView 与 layoutContent()")
    check("S-31", "冷启动 openFiles 先缓存再入列",
          "pendingURLs" in src and "uiReady" in src,
          "缺少 pendingURLs/uiReady 保护，冷启动双击 PDF 会崩溃")
    check("S-32", "子进程 PATH 补全（Homebrew）",
          "childEnvironment" in src and "/opt/homebrew/bin" in src,
          "OCR 子进程需补 PATH，否则 Finder 启动时找不到 tesseract")
    check("S-30", "工厂函数支持 toolTip（悬停提示）",
          re.search(r"func label\(_ t: String, tip: String\? = nil\)", src) is not None
          and "toolTip" in src, "label/check/button 需支持可选 tip:")


# --------------------------------------------------------- B. CLI 契约（无 OCR）
def section_b(tmp):
    print("\nB. CLI 契约（解析 / 退出码）")

    rc, out, err, _ = cli("--help")
    check("C-B1", "--help 退出码 0 且含用法", rc == 0 and "用法:" in out, f"rc={rc}")

    rc, out, _, _ = cli("-h")
    check("C-B1", "-h 退出码 0", rc == 0, f"rc={rc}")

    rc, out, err, _ = cli("--mode", "bogus", "x.pdf")
    check("C-B5", "--mode 非法值报错退出 2", rc == 2 and "未知的 --mode" in err, f"rc={rc} err={err.strip()[:80]}")

    rc, out, err, _ = cli("--jobs", "abc", "x.pdf")
    check("C-B7", "--jobs 非整数报错退出 2", rc == 2 and "需要整数" in err, f"rc={rc}")

    rc, out, err, _ = cli("--lang", "  ", "x.pdf")
    check("C-B6", "--lang 空值报错退出 2", rc == 2 and "--lang" in err, f"rc={rc} err={err.strip()[:80]}")

    rc, out, err, _ = cli("--jobs")
    check("C-B8", "--jobs 缺值报错退出 2", rc == 2 and "缺少取值" in err, f"rc={rc}")

    # --out 吞掉下一个选项：必须报错，而不是把它当目录名
    rc, out, err, _ = cli("--out", "--deskew", "a.pdf")
    check("C-B9", "--out 后跟 --选项 判为取值缺失", rc == 2 and "缺少取值" in err, f"rc={rc} err={err.strip()[:80]}")

    # 未知的 - 开头 token
    rc, out, err, _ = cli("-x.pdf")
    check("C-B3", "未知 - 选项报错退出 2", rc == 2 and "未知参数：-x.pdf" in err, f"rc={rc} err={err.strip()[:60]}")

    rc, out, err, _ = cli("--bogus", "a.pdf")
    check("C-B4", "未知 -- 选项报错退出 2", rc == 2 and "未知参数：--bogus" in err, f"rc={rc}")

    rc, out, err, _ = cli("no-such-file.pdf")
    check("C-B11", "输入不存在报错退出 2", rc == 2 and "不存在" in err, f"rc={rc} err={err.strip()[:60]}")

    rc, out, err, _ = cli()
    check("C-B10", "无输入打印用法退出 2", rc == 2 and "用法:" in out, f"rc={rc}")

    # 磁盘上不存在的 - 开头 token → 未知选项（退出 2）
    rc, out, err, _ = cli("-0-missing.pdf", cwd=tmp)
    check("C-B4", "- 开头且不存在 → 未知参数退出 2",
          rc == 2 and "未知参数" in err, f"rc={rc} err={err.strip()[:60]}")

    # 文件名以 - 开头：磁盘存在 → 按输入接受，并补 ./ 前缀交给引擎
    dash = os.path.join(tmp, "-x.pdf")
    shutil.copyfile(os.path.join(ROOT, "test", "samples", "invoice_en.pdf"), dash) \
        if os.path.exists(os.path.join(ROOT, "test", "samples", "invoice_en.pdf")) else None
    if os.path.exists(dash):
        # 加 ./ 前缀的显式写法
        rc, out, err, _ = cli("--lang", "eng", "--out", os.path.join(tmp, "dash-out"), "./-x.pdf", cwd=tmp)
        line = next((l for l in out.splitlines() if l.startswith("[OK]")), "")
        check("C-B3", "./-x.pdf 作为输入被接受并完成识别",
              rc == 0 and "-x_ocr.pdf" in line and "chars=" in line,
              f"rc={rc} out={out.strip()[:100]!r} err={err.strip()[-80:]!r}")

        # 裸 "-x.pdf"：CLI 须补 ./ 前缀后交给引擎，而不是原样透传（会被 ocrmypdf 当作选项）
        rc, out, err, _ = cli("--lang", "eng", "--out", os.path.join(tmp, "dash-out2"), "-x.pdf", cwd=tmp)
        line = next((l for l in out.splitlines() if l.startswith("[OK]")), "")
        check("C-B12", "裸 -x.pdf 判为文件输入并补 ./ 前缀",
              rc == 0 and "-x_ocr.pdf" in line, f"rc={rc} out={out.strip()[:100]!r} err={err.strip()[-80:]!r}")


# ---------------------------------------------------- C. 输出 / 收集（无 OCR 或轻量）
def ocr_line(out):
    """取 stdout 第一行 [OK] 并按制表符切分；返回 (源名, 输出路径) 或 (None, None)。"""
    line = next((l for l in out.splitlines() if l.startswith("[OK]")), "")
    parts = line.split("\t")
    return (parts[1], parts[2]) if len(parts) >= 3 else (None, None)


def section_c(tmp):
    print("\nC. 输入收集与输出命名")
    # 构造带子目录、隐藏文件、非目标扩展的目录树
    tree = os.path.join(tmp, "tree")
    os.makedirs(os.path.join(tree, "sub"), exist_ok=True)
    samples = os.path.join(ROOT, "test", "samples")
    en = os.path.join(samples, "invoice_en.pdf")
    if not os.path.exists(en):
        record(SKIP, "C-C4", "目录递归收集（样例缺失，跳过）", "需要 test/samples 样例")
        return
    shutil.copyfile(en, os.path.join(tree, "a.pdf"))
    shutil.copyfile(en, os.path.join(tree, "sub", "b.pdf"))
    shutil.copyfile(en, os.path.join(tree, "sub", "c.png"))
    open(os.path.join(tree, "note.txt"), "w").close()
    open(os.path.join(tree, ".hidden.pdf"), "w").close()

    # --- C-C4/C-C5：递归收集范围 ---
    out_dir = os.path.join(tmp, "out-tree")
    rc, out, err, _ = cli("--lang", "eng", "--out", out_dir, tree)
    ok_lines = [l for l in out.splitlines() if l.startswith("[OK]")]
    names = sorted(l.split("\t")[1] for l in ok_lines if "\t" in l)
    check("C-C4", "递归收集：3 个目标文件（含子目录图片）",
          rc == 0 and names == ["a.pdf", "b.pdf", "c.png"], f"rc={rc} got={names} err={err.strip()[-100:]}")
    check("C-C5", "排除 .txt 与非隐藏过滤，文字层非空",
          "note.txt" not in out and all("chars=0" not in l for l in ok_lines),
          f"out={out.strip()[:160]}")

    # --- C-C1/C-C2：默认命名与冲突加序号（每次独立目录，避免相互干扰）---
    naming = os.path.join(tmp, "out-name")
    rc, out, err, _ = cli("--lang", "eng", "--out", naming, os.path.join(tree, "a.pdf"))
    _, p1 = ocr_line(out)
    check("C-C1", "默认输出名 <原名>_ocr.pdf",
          p1 is not None and os.path.basename(p1) == "a_ocr.pdf" and os.path.isfile(p1),
          f"path={p1!r} rc={rc}")

    rc, out, err, _ = cli("--lang", "eng", "--out", naming, os.path.join(tree, "a.pdf"))
    _, p2 = ocr_line(out)
    check("C-C2", "同名冲突自动加序号 _ocr_2.pdf（不覆盖）",
          p2 is not None and os.path.basename(p2) == "a_ocr_2.pdf",
          f"path={p2!r} rc={rc}")

    rc, out, err, _ = cli("--lang", "eng", "--out", naming, os.path.join(tree, "a.pdf"))
    _, p3 = ocr_line(out)
    check("C-C2", "再次冲突递增为 _ocr_3.pdf",
          p3 is not None and os.path.basename(p3) == "a_ocr_3.pdf",
          f"path={p3!r} rc={rc}")

    # --- C-C1：图片输入的输出名沿用原基名（经 sips 转 PDF）---
    img_out = os.path.join(tmp, "out-img")
    rc, out, err, _ = cli("--lang", "eng", "--out", img_out, os.path.join(tree, "sub", "c.png"))
    _, pi = ocr_line(out)
    check("C-C1", "图片输入输出名 <原名>_ocr.pdf",
          pi is not None and os.path.basename(pi) == "c_ocr.pdf" and os.path.isfile(pi),
          f"path={pi!r} rc={rc} err={err.strip()[-100:]}")

    # --- S-10：CLI 报告的路径必须是绝对路径（相对输入也要落到绝对路径）---
    rc, out, err, _ = cli("--lang", "eng", "--out", os.path.join(tmp, "out-rel"), "tree/a.pdf", cwd=tmp)
    _, pr = ocr_line(out)
    check("S-10", "相对输入 → 输出为绝对路径",
          pr is not None and os.path.isabs(pr), f"path={pr!r} rc={rc} err={err.strip()[-100:]}")


# ------------------------------------------------------- D. 真实 OCR 段落
def section_d(tmp):
    print("\nD. 识别与结果校验（真实 OCR，较慢）")
    if shutil.which("ocrmypdf") is None and not os.path.exists("/opt/homebrew/bin/ocrmypdf"):
        for sid, nm in [("C-D1", "英文样例文字层"), ("C-D3", "中文样例文字层"),
                        ("C-D2", "中英混排文字层"), ("C-D4", "倾斜+噪点纠偏")]:
            record(SKIP, sid, nm + "（引擎缺失，跳过）")
        return

    gen_dir = os.path.join(tmp, "gen")
    os.makedirs(gen_dir, exist_ok=True)
    out_dir = os.path.join(tmp, "ocrout")
    os.makedirs(out_dir, exist_ok=True)

    def gen(name, pages, kind, stress=False):
        args = [TOOL, "gen", os.path.join(gen_dir, name), str(pages), kind]
        if stress:
            args.append("stress")
        rc, out, err, _ = run(args)
        return rc == 0

    gen("en.pdf", 2, "en")
    gen("zh.pdf", 2, "zh")
    gen("mixed.pdf", 3, "mixed")
    gen("tilt.pdf", 2, "zh", stress=True)

    rc, out, err, dt = cli("--lang", "chi_sim+eng", "--mode", "skip", "--jobs", "4",
                           "--out", out_dir, gen_dir)
    check("C-D1", "批量 OCR 退出码 0", rc == 0, f"rc={rc} err={err.strip()[-120:]}")

    def chars_of(name):
        path = os.path.join(out_dir, name)
        if not os.path.exists(path):
            return -1
        rc, out, err, _ = run([TOOL, "inspect", path])
        m = re.search(r"chars=(\d+)", out)
        return int(m.group(1)) if m else -1

    c_en = chars_of("en_ocr.pdf")
    check("S-20", "英文样例 chars>0", c_en > 100, f"chars={c_en}")
    c_zh = chars_of("zh_ocr.pdf")
    check("S-20", "中文样例 chars>0", c_zh > 100, f"chars={c_zh}")
    c_mixed = chars_of("mixed_ocr.pdf")
    check("S-20", "中英混排样例 chars>0", c_mixed > 100, f"chars={c_mixed}")

    # 关键词命中（归一化去空格）
    def norm(name):
        path = os.path.join(out_dir, name)
        if not os.path.exists(path):
            return ""
        rc, out, err, _ = run([TOOL, "inspect", path])
        return out.replace(" ", "")

    en_txt = norm("en_ocr.pdf")
    check("C-D1", "英文样例关键词命中", "INVOICE" in en_txt and "INV-2026-0930" in en_txt,
          en_txt[-100:])

    # 页数一致
    rc, out, err, _ = run([TOOL, "inspect", os.path.join(out_dir, "mixed_ocr.pdf")])
    m = re.search(r"pages=(\d+)", out)
    check("S-21", "输出页数与输入一致（3 页）", m and m.group(1) == "3", out[:80])

    # 倾斜压测：开纠偏+去噪
    rc, out, err, _ = cli("--lang", "chi_sim+eng", "--mode", "skip", "--jobs", "4",
                          "--deskew", "--clean", "--out", out_dir,
                          os.path.join(gen_dir, "tilt.pdf"))
    c_tilt = chars_of("tilt_ocr.pdf")
    check("C-D4", "倾斜+噪点开纠偏后 chars>0", rc == 0 and c_tilt > 100, f"rc={rc} chars={c_tilt}")


# ------------------------------------------------------------ E. 确定性
def section_e(tmp):
    print("\nE. 确定性")
    if not os.path.isfile(TOOL):
        record(SKIP, "C-E1", "样例确定性（缺 sample_tool）")
        return
    d1 = os.path.join(tmp, "e1.pdf")
    d2 = os.path.join(tmp, "e2.pdf")
    run([TOOL, "gen", d1, "2", "zh", "stress"])
    run([TOOL, "gen", d2, "2", "zh", "stress"])
    # 比较渲染后的像素哈希，而不是文件字节：CGContext 会把生成时间写进 PDF 的
    # CreationDate/ID，两次生成的原始字节必然不同，但图像内容必须逐像素一致。
    def ph(p):
        if not os.path.exists(p):
            return None
        rc, out, err, _ = run([TOOL, "pixelhash", p])
        m = re.search(r"hash=([0-9A-F]+)", out)
        return m.group(1) if m else None

    h1, h2 = ph(d1), ph(d2)
    check("C-E1", "同参数两次生成的压测样例图像内容一致（噪点种子固定）",
          h1 is not None and h1 == h2, f"{h1} vs {h2}")


# ------------------------------------------------------------------ 主流程
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fast", action="store_true", help="跳过真实 OCR 段（D 段）")
    args = ap.parse_args()

    must_exist(CLI)
    must_exist(TOOL)

    print(f"BatchOCR 契约 harness —— 对照 {os.path.relpath(SPEC, ROOT)}")
    tmp = tempfile.mkdtemp(prefix="batchocr-harness-")
    try:
        section_a()
        section_f()
        section_b(tmp)
        section_e(tmp)
        if args.fast:
            record(SKIP, "C-C*", "输入收集/输出命名（--fast 跳过）")
            record(SKIP, "C-D*", "识别段（--fast 跳过）")
        else:
            section_c(tmp)
            section_d(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    passed = sum(1 for r in results if r[0] == PASS)
    failed = sum(1 for r in results if r[0] == FAIL)
    skipped = sum(1 for r in results if r[0] == SKIP)
    print(f"\n{'=' * 56}")
    print(f"harness 结果：{passed} 通过 · {failed} 失败 · {skipped} 跳过")
    if failed:
        print("\n失败明细：")
        for st, sid, name, detail in results:
            if st == FAIL:
                print(f"  [{sid}] {name} — {detail}")
        print("\nHARNESS FAILED ❌")
        return 1
    print("HARNESS PASSED ✅")
    return 0


if __name__ == "__main__":
    sys.exit(main())
