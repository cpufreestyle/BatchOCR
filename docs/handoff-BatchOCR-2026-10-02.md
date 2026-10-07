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

## 9. 修复记录（2026-10-02）

针对只读审查发现的问题已全部修复并实测：

- CLI 取值不再吞掉下一个 `--` 选项（`--out --deskew a.pdf` 原先会建出名为 `--deskew` 的目录，现报错退出 2）
- `--jobs` 与 GUI stepper 统一夹到 `1...16`；`0`/`-3`/`999` 不再透传给引擎
- `--mode` 未知值改为报错；`--lang` / `--jobs` 缺值与非法整数也会报错
- 目录输入改为**递归**收集，且同时接受 PDF 与图片，与 GUI 拖入/选文件夹一致
- `--out` 与输入路径正确展开 `~`
- `Info.plist` 最低系统版本 12.0 → 14.0（`NSApplication.activate()` 需要 macOS 14），并补充 png/jpeg/tiff 文档类型
- 新增 `LICENSE`（MIT）与 `resources/AppIcon.icns`（`tools/make_icon.swift` 可复现生成，`build.sh` 自动拷入）
- README / 本文档数字校正：文字层 445 / 262 / 473，ocrmypdf 17.13.0，双远端 main 已同步

## 10. 修复记录（2026-10-04）

- GUI 复杂控件补齐悬停解释（`toolTip`）：语言下拉、模式下拉（三种「跳过／重做／强制」区别）、四个复选（自动纠偏／去噪／自动旋转／输出 PDF/A）、并行页数 stepper、输出下拉，以及添加／移除／清空／开始 OCR／打开输出文件夹按钮，另加表格与状态提示
- 说明文案统一为「它做什么 + 什么时候用」的一句白话，多行项用换行分点
- 工厂函数 `label` / `check` / `button` 增加可选 `tip:` 参数，新增控件只需传文案
- 回归：`./build.sh` 通过；`./test/run_tests.sh` → ALL TESTS PASSED ✅；GUI 实测悬停提示正常弹出

### 10.1 UI 紧凑化 + 两个启动期缺陷（2026-10-04）

- 删除底部「语言包」整行长列表：原先把 160+ 个已装语言名平铺成一行，撑满窗口宽度且无实用价值；语言清单本就在识别语言下拉里
- 拖拽提示从固定一行改为叠加在表格中央，只在队列为空时显示；有文件后自动隐去，不再占固定行高
- 三行选项合并为两行（「语言 + 模式」一行，「开关 + 并行 + 输出」一行），默认窗口底部留白从约 185pt 收到约 77pt，最小窗口高度 600 → 380
- 底部引擎行只在引擎缺失时才显示（正常时隐藏，不占空间）
- 修复：Finder 冷启动双击 PDF 会崩溃 —— `openFiles` 早于窗口构建，`addURLs` 对尚未创建的控件取值（EXC_BREAKPOINT，自 2026-09-30 起存在）；改为控件就绪前先缓存 URL，就绪后补入列
- 修复：Finder / Dock 启动时进程只继承极简 PATH，ocrmypdf 找不到 tesseract（退出码 3）；子进程环境补上 `/opt/homebrew/bin` 与引擎所在目录
- 回归：`./build.sh` 通过；`./test/run_tests.sh` → ALL TESTS PASSED ✅；GUI 冷启动双击入列 → 开始 OCR → 完成 2 · 失败 0

## 11. 修复记录（2026-10-07）：建立 SPEC 契约与 harness

### 11.1 动机

此前的验证只有 `test/run_tests.sh` 一条路径，它断言 OCR 的**识别质量**：生成仿真扫描件、跑批量识别、检查文字层字符量与关键词。
这条路径有两个盲区：

1. **数值不可复现**：`sample_tool` 渲染噪点用 `CGFloat.random`，每跑一次生成的扫描件都不同，README 里的「301→315 字符」只是某一次的观测值，重跑不一定成立。
2. **契约没人守**：CLI 的选项语义、退出码、输出命名规则、GUI 的源码不变量（手动布局、冷启动缓存、子进程 PATH），没有任何自动化检查在改坏时报警。

### 11.2 新增的正式契约（`docs/SPEC.md`）

把散落在 README、代码注释里的口头约定整理为编号条目，每条都标注「谁来验证」：

- **§2 版本与产物**（S-01…S-03）：版本号在 `Sources/main.swift` 与 `Info.plist` 双处一致、`./build.sh` 产物清单、最低系统版本 14.0 与文档类型声明。并明确规定：改版本必须同时改两处。
- **§3 CLI 契约**：完整选项表（含每个选项的取值域与守卫）、退出码语义（0 成功 / 1 有失败 / 2 用法与环境错）、stdout 的 `[OK]\t文件\t路径\tpages=N\tchars=M` 行格式、stderr 进度行、输出命名 `<原名>_ocr.pdf` 与冲突递增 `_2`/`_3`。
- **§4 识别与结果校验**（S-20…S-23）：chars>0、页数一致、倾斜压测、以及**确定性**这一条。
- **§5 GUI 不变量**（S-30…S-35）：flipped 手动布局不得回退 NSStackView、冷启动 `pendingURLs`/`uiReady` 缓存、子进程 PATH 补全、isRunning 禁用、拖拽浮层、toolTip。
- **§7 变更流程**：改行为 → 先改 SPEC → 加 harness 检查 → `./build.sh && python3 test/harness.py` 通过 → 提交。

### 11.3 新增的契约 harness（`test/harness.py`）

只依赖标准库与已构建产物，按 SPEC 编号分段，每条断言都标注来源编号，失败时直接定位到契约条目。当前 **38 条断言全绿**：

| 段 | 条数 | 断言内容 |
|---|---|---|
| A | 5 | 版本一致性、`--version`、最低系统版本、文档类型（plistlib 读 Info.plist） |
| B | 14 | 每个选项的取值守卫、退出码语义、`-` 开头 token 归属判定 |
| C | 8 | 目录递归收集范围、默认命名、冲突递增、图片输入命名、输出为绝对路径 |
| D | 7 | 三类样例文字层、页数一致、倾斜 + 纠偏压测（真实 OCR） |
| E | 1 | 同参数两次生成的样例图像内容逐像素一致 |
| F | 4 | GUI 源码静态不变量 |

用法：

```bash
python3 test/harness.py           # 全量约 20 秒
python3 test/harness.py --fast    # 跳过真实 OCR 段，约 3 秒
```

退出码 0/1，末行输出 `HARNESS PASSED ✅` / `HARNESS FAILED ❌`。
引擎缺失（未装 ocrmypdf）时 D 段自动 SKIP 而不是误报失败。

### 11.4 顺带修掉的两个实现问题

**（a）`-` 开头文件名的参数误读**

CLI 原先对所有 `-` 开头 token 一律判「未知参数」，于是目录里真有个 `-x.pdf` 时无法处理；
而改成无脑接受又会让手误的选项拼写静默变成文件路径。最终规则是**先查磁盘**：
同名文件存在 → 按输入接受，并自动补 `./` 前缀后交给 ocrmypdf（原样传会被引擎当成选项）；
不存在 → 报「未知参数」退出 2。SPEC 的 S-11 已按此改写，harness 补了 C-B4 与 C-B12 两条断言分别钉住两个分支。

**（b）噪点随机导致样例不可复现**

`sample_tool` 的 `renderPageImage` 改用固定种子的 xorshift64*（`SeededRandom`，种子 `0xBC0C_2026_1004`），
同参数两次生成的扫描件图像内容完全一致。SPEC 的 S-23 明确规定**只断言图像内容**：
CGContext 会把生成时间写进 PDF 的 `CreationDate`/`ID`，原始字节必然每次不同，拿 SHA-256 比文件是错的断言。
为此给 `sample_tool` 加了 `pixelhash` 子命令（渲染各页后做 FNV-1a 像素哈希），harness 的 E 段用它比对。

### 11.5 踩到的坑

- **确定性断言的粒度**：一开始用 SHA-256 比整个 PDF，结果两次必然不同（CGContext 写时间戳）。先怀疑是种子没生效，
  用 `cmp -l` 数出只差 58 字节、且全部落在 PDF trailer 的日期/ID 字段，才确认种子是对的、断言写粗了。
- **harness 自己污染夹具**：C 段最初三个用例共用一个输出目录，导致「默认命名」断言测到的其实是 `_ocr_2.pdf`。
  这是 harness 的 bug，不是实现的 bug——每个命名用例现在各自用独立目录。
- **README 用 heredoc 写会炸**：`<<EOF`（未加引号）时文档里的反引号被 shell 当命令执行，把正文切成逐字符碎片。
  必须用带引号的 `<<'EOF'`，或干脆写文件再由 Python 读取插入。

### 11.6 回归结果

- `./build.sh` → 通过（无警告）
- `python3 test/harness.py` → **38 通过 · 0 失败 · 0 跳过**
- `python3 test/harness.py --fast` → 24 通过 · 0 失败 · 2 跳过
- `./test/run_tests.sh` → `ALL TESTS PASSED ✅`，字符数 445 / 262 / 473 现已稳定复现；压测 261 / 257

### 11.7 两套脚本的分工（别合并）

`run_tests.sh` 与 `harness.py` 故意保持独立，因为失败信息的含义不同：

- `run_tests.sh` 失败 → **识别质量**出问题：引擎版本、语言包、渲染质量。它的数值会随 tesseract 版本浮动。
- `harness.py` 失败 → **行为契约**被破坏：改坏了选项语义、改名规则、版本漂移、GUI 不变量。它必须稳定可重复，否则等于没有检查。

合二为一会让两者互相拖累（识别质量的浮动让契约检查偶发失败），反而失去意义。

### 11.8 交接给下一轮

- SPEC 里 S-33（isRunning 禁用）、S-34（拖拽浮层）、S-35（toolTip）仍是人工验证项，因为 GUI 不可在 harness 里驱动。
  S-35 已由源码静态检查覆盖大半（工厂函数带 `tip:` 参数 + 各控件赋值）；S-33/S-34 若要自动化，需要辅助功能（AX）探测或截图比对。
- `harness.py` 的 C 段依赖 `test/samples/invoice_en.pdf`（`.gitignore` 忽略）。样例缺失时该段 SKIP 并提示，跑 `./test/run_tests.sh` 会生成。
- SPEC §7 的流程已写进文档，但没有 CI 卡点（无 Xcode 工程、无 GitHub Actions）。若要自动化，把 `./build.sh && python3 test/harness.py --fast` 挂上去即可。
