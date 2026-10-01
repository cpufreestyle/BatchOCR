#!/bin/bash
# 端到端验证：生成仿真扫描件 → 确认无文字层 → 批量 OCR → 断言文字层与关键词
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
TOOL="$ROOT/build/sample_tool"
CLI="$ROOT/build/BatchOCR.app/Contents/MacOS/BatchOCR"
SAMPLES="$ROOT/test/samples"
OUT="$ROOT/test/out"
mkdir -p "$SAMPLES" "$OUT"
rm -f "$SAMPLES"/*.pdf "$OUT"/*.pdf
FAIL=0

echo "== 1. 生成仿真扫描件（纯图片、无文字层）=="
"$TOOL" gen "$SAMPLES/invoice_en.pdf" 2 en || FAIL=1
"$TOOL" gen "$SAMPLES/发票_zh.pdf" 2 zh || FAIL=1
"$TOOL" gen "$SAMPLES/report_mixed.pdf" 3 mixed || FAIL=1

echo
echo "== 2. 确认输入无文字层（chars 必须为 0）=="
for f in "$SAMPLES"/*.pdf; do
  LINE=$("$TOOL" inspect "$f")
  echo "  $(basename "$f") → $LINE"
  CHARS=$(echo "$LINE" | sed -E 's/.*chars=([0-9]+).*/\1/')
  if [ "$CHARS" != "0" ]; then echo "  FAIL: $f 竟然已有文字层"; FAIL=1; fi
done

echo
echo "== 3. 运行批量 OCR（CLI 模式，chi_sim+eng，4 并行）=="
"$CLI" --cli --lang "chi_sim+eng" --mode skip --jobs 4 --out "$OUT" "$SAMPLES"/*.pdf || FAIL=1

echo
echo "== 4. 校验输出文字层与关键词命中 =="
check() { # $1=输出文件 其余=关键词（至少命中 2 个）
  local f="$1"; shift
  if [ ! -f "$f" ]; then echo "  FAIL: 缺少输出 $f"; FAIL=1; return; fi
  local LINE=$("$TOOL" inspect "$f")
  echo "  $(basename "$f") → $(echo "$LINE" | cut -c1-100)..."
  # OCR 会在中文字符间插入空格，去掉所有空白后再匹配关键词
  local NORM=$(echo "$LINE" | tr -d ' ')
  local CHARS=$(echo "$LINE" | sed -E 's/.*chars=([0-9]+).*/\1/')
  local HITS=0
  for kw in "$@"; do
    if echo "$NORM" | grep -q "$kw"; then HITS=$((HITS+1)); fi
  done
  if [ "${CHARS:-0}" -le 150 ]; then echo "  FAIL: $f 文字层字符过少 ($CHARS)"; FAIL=1; fi
  if [ "$HITS" -lt 2 ]; then echo "  FAIL: $f 关键词命中不足 ($HITS/4)"; FAIL=1; fi
}
check "$OUT/invoice_en_ocr.pdf"    "INVOICE" "Acme" "September" "business"
check "$OUT/发票_zh_ocr.pdf"       "发票" "金额" "科技" "转账"
check "$OUT/report_mixed_ocr.pdf"  "Quarterly" "季度" "营收" "内部"

echo
echo "== 5. 恶劣条件压测（页面旋转 2° + 40k 噪点，开纠偏/去噪）=="
"$TOOL" gen "$SAMPLES/scan_tilted.pdf" 2 zh stress || FAIL=1
"$CLI" --cli --lang chi_sim+eng --mode skip --jobs 4 --deskew --clean \
       --out "$OUT" "$SAMPLES/scan_tilted.pdf" || FAIL=1
check "$OUT/scan_tilted_ocr.pdf" "发票" "金额" "转账" "科技"

echo
echo "== 6. 体积对比 =="
for f in "$SAMPLES"/*.pdf; do
  B=$(stat -f%z "$f")
  O=$(stat -f%z "$OUT/$(basename "${f%.pdf}")_ocr.pdf" 2>/dev/null || echo 0)
  printf "  %-24s %9d → %9d bytes\n" "$(basename "$f")" "$B" "$O"
done

echo
if [ "$FAIL" = "0" ]; then echo "ALL TESTS PASSED ✅"; else echo "TESTS FAILED ❌"; fi
exit $FAIL
