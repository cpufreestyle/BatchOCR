# 交接文档 — BatchOCR（批量 PDF OCR，Mac）

> 交接日期：2026-10-02
> 项目位置：`/Users/a1-6/AI Shared/repo/BatchOCR`
 > 仓库：Gitee 与 GitHub 双公开远端，两端 main 已同步（见 §5-2）
> - Gitee：https://gitee.com/cpufreestyle/BatchOCR （remote 名 `origin`，**主远端**）
> - GitHub：https://github.com/cpufreestyle/BatchOCR （remote 名 `github`）

---

## 1. 项目一句话

把扫描件/图片型 PDF **批量**变成**可搜索 PDF** 的 Mac 原生应用（GUI + CLI 双模式）。
识别引擎基于开源 **OCRmyPDF（MPL-2.0）+ Tesseract（Apache-2.0）**，本项目在其上补齐付费软件才有的 Mac 批量图形界面、参数配置、结果校验与 CLI 自动化。

**选型逻辑**（立项依据，详见 README §1）：对标 Nitro PDF Pro（~$130–180 买断）/ ABBYY FineReader（订阅）的批量 OCR 功能；「无免费替代」论证：macOS Live Text 只能单页交互、免费 OCR GUI 有水印/限制、OCRmyPDF 本体是纯命令行。

## 2. 当前状态：已完成并全量验证 ✅

| 事项 | 状态 | 证据 |
|---|---|---|
| 应用构建 | ✅ `build/BatchOCR.app`（ad-hoc 签名，260KB） | `./build.sh`，swiftc 6.4 / macOS 27 arm64 |
| 端到端测试 | ✅ ALL TESTS PASSED | `./test/run_tests.sh`（5 段断言） |
| GUI | ✅ 启动、布局、`open -a` 入列均截图验证 | 表格/选项/按钮完整渲染 |
| 仓库同步 | ✅ 双远端 HEAD 一致 | `git ls-remote` 验证 |

**核心实测数据**（chi_sim+eng，4 页并行）：

- 英文发票：445 字符，`INVOICE Invoice Number: INV-2026-0930 Total Amount Due: $1,234.56` 近乎完美
 - 中文发票：262 字符，关键词命中；中英混排：473 字符全命中
- **压测**（页面旋转 2° + 4 万噪点）：不开纠偏 → 大写金额乱码（`ARMS TAGS…`）；`--deskew --clean` → 315 字符关键词全命中，且输出页被自动摆正、去噪（付费软件宣传的"扫描件修复"效果）

## 3. 结构与关键文件

```
BatchOCR/
├── Sources/main.swift      # 全部应用代码：GUI（AppKit 手动布局）+ CLI + 引擎封装
├── tools/sample_tool.swift # 验证工具：gen 生成仿真扫描件（支持 stress 压测）/ inspect 检查文字层
├── resources/Info.plist
├── build.sh                # swiftc 构建（无需 Xcode 工程）
├── setup.sh                # 引擎安装 + 中文语言包补齐
├── test/run_tests.sh       # 端到端测试（1 生成→2 无文字层断言→3 OCR→4 关键词→5 压测→6 体积）
└── README.md               # 选型论证/功能对照/使用说明
```

- GUI 布局：**flipped 坐标 + `layout()` 手动计算 frame**（DropView 子类）。第一版用 NSStackView+约束导致控件不渲染，已废弃该方案——改布局时保持手动方式。
- 双模式入口：`main.swift` 顶层判断 `--cli` 进 CLI，否则 GUI。
- 结果校验用 PDFKit 提取文字层字符数（引擎返回 + 状态列展示 `完成 ✓ · N 字符`）。

## 4. 环境依赖（本机已装好）

 - `ocrmypdf 17.13.0`（brew，自动带 tesseract/ghostscript/qpdf；tesseract 5.5.3）
- tesseract 语言包 163 种（含 chi_sim/chi_tra/jpn），`/opt/homebrew/share/tessdata/`
- Xcode 26 / Swift 6.4（构建用 `-swift-version 5` 规避严格并发）
- 凭据：`~/.git-credentials`（gitee oauth2 token + github PAT `ghp_…LPLTG`，权限 600）

## 5. 踩过的坑（重要）

1. **GUI 首次启动不投递文件事件**：`open -a BatchOCR.app 文件.pdf` 在应用第一次启动时 odoc 事件常被 LaunchServices 丢弃；对**运行中**实例重发即可。已写入 README。
2. **GitHub 网络间歇性阻断**：到 github.com 的 HTTPS 时通时断（可用时握手 ~6 秒；阻断时表现为 75s 连接超时或 `SSL_ERROR_SYSCALL`，连 curl 也会挂起）。早前 GitHub 一度落后 2 个 docs 提交（卡在 `96962bb`），2026-10-02 网络恢复后已 `git push github main` 补齐，两端 main 一致。仍**以 Gitee（origin）为主远端**——它始终稳定。另：8888 端口不是 HTTP 代理；SSH 经 SOCKS 1082 不通；gh CLI keyring token 已失效（现在用 ~/.git-credentials 里的 PAT）。
3. **中文 OCR 断言**：Tesseract 会在中文字符间插空格（`发 票`），测试脚本 grep 前必须 `tr -d ' '` 归一化；`inspect` 输出 sample 已扩到 2000 字符。
4. **`.mimosa/` 工具状态目录**：Mimosa hook 会在仓库内写运行时状态，已在 `.gitignore`（提交 `96962bb`）。若再用 `git add -A` 注意勿重新跟踪。
5. **Swift 6 编译**：必须 `-swift-version 5`；CGPDF 用 `CGContext(url:mediaBox:)` 新接口；`NSAttributedString.Key` 需 `as String` 转换。

## 6. 常用命令速查

```bash
cd "/Users/a1-6/AI Shared/repo/BatchOCR"

./build.sh                    # 构建（产物 build/BatchOCR.app + build/sample_tool）
./test/run_tests.sh           # 端到端验证（应输出 ALL TESTS PASSED ✅）
open build/BatchOCR.app       # GUI（拖 PDF 入列 → 开始 OCR → 输出 原名_ocr.pdf）
build/BatchOCR.app/Contents/MacOS/BatchOCR --cli \
  --lang chi_sim+eng --mode skip --jobs 4 --out 输出目录 文件1.pdf 目录/
./build/sample_tool inspect 某文件.pdf   # 输出 pages/chars/sample
git push origin main && git push github main   # 双远端同步
```

## 7. 未完成 / Roadmap

- [ ] 监视文件夹自动 OCR（丢文件进目录即处理）
- [ ] 语言包管理界面（在线下载 traineddata）
- [ ] PDF/A-3、缩略图预览列
- [ ] 公开发布前的完整安全审计（Mimosa 提示 callgraph partial，未跑全量）
- [ ] （可选）DMG 打包 + 公证，脱离 ad-hoc 签名

## 8. 会话记忆

本项目的立项决策、测试结果、迁移与凭据状态均已存 MemOS（检索关键词：BatchOCR、同步仓库、测试效果）。接手会话可先 `memos search "BatchOCR"`。
