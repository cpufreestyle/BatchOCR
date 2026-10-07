# BatchOCR — 批量 PDF OCR（Mac）

把扫描件/图片型 PDF **批量**变成**可搜索 PDF** 的 Mac 原生应用（GUI + CLI 双模式）。
识别引擎完全基于开源软件：**[OCRmyPDF](https://github.com/ocrmypdf/OCRmyPDF)（MPL-2.0）+ [Tesseract](https://github.com/tesseract-ocr/tesseract)（Apache-2.0）**，本项目在其上补齐了付费软件才提供的 Mac 批量图形界面、结果校验与自动化接口。

---

## 1. 选型论证：为什么做这个

### 目标付费软件（本项目对标复刻的核心功能）

| 付费软件 | 价格 | 相关功能 |
|---|---|---|
| [Nitro PDF Pro](https://www.gonitro.com/pdf-pro)（原 PDFpen） | ~$130–180 买断 | 批量 OCR 生成可搜索 PDF（Mac 版核心卖点之一） |
| [ABBYY FineReader PDF](https://pdf.abbyy.com/) | 订阅 ~$100–200/年 | 批量 OCR、多语言识别、输出可搜索 PDF |

### 「没有免费软件可以替代」的依据

1. **macOS 自带 Live Text 不算替代**：只能在预览界面里单页、交互式地取词/拷贝，不能批量处理文件，也不能把识别结果写回成可搜索 PDF。
2. **App Store 免费小工具不算替代**：免费档普遍带水印、页数/次数限制或强制订阅，批量能力残缺。
3. **OCRmyPDF 本体是纯命令行**：能力强大但对普通用户不可用——这正是本项目补齐的部分（批量队列、参数界面、进度与结果校验），等价于付费软件的 GUI 价值层。

### 「以开源软件为基础」的构成

- 识别引擎：OCRmyPDF（编排：栅格化、纠偏、文字层合成）+ Tesseract（OCR 识别）
- 依赖链：Ghostscript（AGPL，栅格化）、qpdf、Leptonica——全部经 Homebrew 安装
- 本项目代码（Swift/AppKit，MIT）：GUI、批量队列、参数映射、结果校验（PDFKit 提取文字层断言）、CLI

---

## 2. 功能对照（付费软件 → BatchOCR）

| 功能 | Nitro/FineReader | BatchOCR |
|---|---|---|
| 批量 OCR 生成可搜索 PDF | ✅ | ✅ 拖拽/添加文件或文件夹，队列执行 |
| 多语言识别（中文简繁/日/英等 160+） | ✅ | ✅ 语言下拉自动检测已装语言包，支持 `chi_sim+eng` 组合 |
| 跳过/重做/强制已有文字层 | ✅ | ✅ 三种模式（--skip-text / --redo-ocr / --force-ocr） |
| 自动纠偏 / 去噪 / 自动旋转 | ✅ | ✅ 开关映射引擎参数 |
| 输出 PDF/A 归档格式 | ✅ | ✅ |
| 并行加速 | ✅ | ✅ 页级并行（--jobs，默认=CPU 数） |
| 结果验证（文字层是否生成） | 部分 | ✅ 逐文件统计可提取字符数，状态列直接显示 |
| 命令行/脚本自动化 | ❌（GUI 为主） | ✅ `--cli` 模式（本仓库测试即用它） |

---

## 3. 构建与安装

```bash
# 1) 引擎依赖（一次性）
brew install ocrmypdf        # 自动带上 tesseract/ghostscript/qpdf
./setup.sh                   # 若缺中文包则自动下载 chi_sim（tessdata_fast）

# 2) 构建
./build.sh                   # 产出 build/BatchOCR.app 与 build/sample_tool
```

## 4. 使用

### GUI

```bash
open build/BatchOCR.app
```

拖入 PDF（或图片，自动转 PDF）→ 选择语言/模式/开关 → 「开始 OCR」。
也支持 `open -a BatchOCR.app 文件1.pdf 文件2.pdf` 或把文件拖到 Dock 图标直接入列
（应用刚装好首次启动时系统可能不投递文件事件，对运行中的实例重发一次即可）。
结果默认写在源目录 `原名_ocr.pdf`，也可切换「输出到指定文件夹」。状态列显示
`完成 ✓ · N 字符 · 体积 ±X%`，即文字层已生成且可搜索。

### CLI（脚本/自动化）

```bash
build/BatchOCR.app/Contents/MacOS/BatchOCR --cli \
    --lang chi_sim+eng --mode skip --jobs 4 --out 输出目录 \
    文件1.pdf 文件2.pdf 目录/
# 每行输出: [OK]\t文件\t输出路径\tpages=N\tchars=M
```

> 文件名以 `-` 开头时（如 `-x.pdf`），CLI 会把它当成文件输入并自动补上 `./` 前缀；目录里没这个文件时会报「未知参数」退出 2。

## 5. 测试（端到端 + 契约）

两套互补的验证入口，都以 `./build.sh` 的产物为被测对象：

```bash
./test/run_tests.sh      # 端到端：断言 OCR 识别质量（文字层字符数、关键词命中、恶劣条件）
python3 test/harness.py  # 契约：逐条对照 docs/SPEC.md 断言行为契约
python3 test/harness.py --fast   # 只跑静态 + CLI 解析契约，跳过真实 OCR（约 3 秒）
```

分工：`run_tests.sh` 断言「识别得对不对」，字符量与关键词会随引擎版本小幅浮动；
`harness.py` 断言「契约是否被遵守」——选项语义、退出码、命名规则、GUI 源码不变量、样例确定性，结果稳定可重复。
harness 全量约 20 秒（含真实 OCR），末行给出结论与退出码：

```
harness 结果：46 通过 · 0 失败 · 0 跳过
HARNESS PASSED ✅
```

下表是 harness 当前覆盖的条目（编号对应 [docs/SPEC.md](docs/SPEC.md)）：

| 段 | 覆盖条目 | 内容 |
|---|---|---|
| A | S-01/S-02/S-03 | 版本号代码与 Info.plist 一致、`--version`/`-v` 输出、最低系统版本与文档类型声明 |
| B | C-B1…C-B12 | 每个选项的取值守卫、退出码语义、`-` 开头 token 的归属判定 |
| C | C-C1…C-C5 | 目录递归收集范围、默认命名与冲突加序号、图片输入命名、输出路径为绝对路径、`--out` 自动建目录/`~` 展开/`--pdfa` |
| D | C-D1…C-D4、S-20/S-21 | 三类样例的文字层、页数一致、倾斜噪点 + 纠偏压测 |
| E | C-E1/S-23 | `sample_tool gen` 两次生成的样例图像内容逐像素一致 |
| F | S-30…S-32 | GUI 源码不变量（手动布局、冷启动缓存、子进程 PATH、toolTip） |
| G | G-01…G-03 | SPEC 与 harness 对账：声称的每个 C-* 都有断言、无孤儿断言、每条 S-xx 都有验证方式 |

### 5.1 端到端验证（识别质量）

```bash
./test/run_tests.sh
```

流程与最近一次实测结果：

1. 用 `sample_tool` 生成 3 个**纯图片、无文字层**的仿真扫描件（英文发票 2 页 / 中文发票 2 页 / 中英混排报告 3 页），`inspect` 确认 chars=0；
2. CLI 批量 OCR（chi_sim+eng，4 并行）：**3 成功 0 失败**；
3. 逐个断言输出：文字层 445 / 262 / 473 字符，中英文关键词命中达标
   （英文样本近乎完美：`INVOICE Invoice Number: INV-2026-0930 Total Amount Due: $1,234.56 …`）；
4. 输出 `ALL TESTS PASSED ✅`。

> 这三组字符数现在可稳定复现：`sample_tool` 的渲染噪点改用固定随机种子（`SeededRandom`），同样的输入不会再造出不同的扫描件。

### 5.2 恶劣条件压测（第 5 段）

`sample_tool gen … stress` 生成「整页旋转 2° + 4 万噪点」的仿真扫描件，对照组/实验组对比：

| 条件 | 命令 | 结果 |
|---|---|---|
| 不开纠偏/去噪 | `--cli` 仅基础参数 | **261 字符**；但大写金额的行首字段被识别成乱码（`ARMS TASER hAD`） |
| **开纠偏+去噪** | `--cli --deskew --clean` | **257 字符**，`总金额/人民币/转账/科技/惠顾` 关键词命中；输出页面被自动摆正、噪点清除（视觉修复） |

实测说明：`--deskew --clean` 不只加文字层，还会把倾斜页面转正、清理噪声——付费软件宣传的"扫描件修复"效果。

> 这组数字同样来自固定种子，重跑一致。倾斜 2° 的压迫下，两组各有丢字段的表现（对照组丢了大写金额的行首小字段、实验组丢了最上方的标题字段），属于 Tesseract 的识别短板而非本项目的逻辑问题——`harness.py` 因此只对该样例断言"有合格文字层"（C-D4），不断言具体关键词。

> 说明：OCR 会在图片型页面上叠加文字层，体积略增（本例 +4%~8%）属正常现象；付费软件同样如此。

## 6. 目录结构

```
BatchOCR/
├── Sources/main.swift      # 应用主程序（GUI + CLI + 引擎封装）
├── tools/sample_tool.swift # 验证工具：生成仿真扫描件 / 检查文字层
├── resources/Info.plist
├── resources/AppIcon.icns  # 应用图标
├── LICENSE                 # MIT
├── build.sh                # 构建（swiftc，无需 Xcode 工程）
├── setup.sh                # 引擎安装与中文语言包补齐
├── test/run_tests.sh       # 端到端验证脚本（识别质量）
├── test/harness.py         # 契约验证脚本（逐条对照 docs/SPEC.md）
├── docs/SPEC.md            # 行为契约：版本、CLI、输出格式、GUI 不变量、变更流程
└── build/BatchOCR.app      # 构建产物（ad-hoc 签名）
```

## 7. 许可证

- 本项目代码：MIT
- OCRmyPDF：MPL-2.0；Tesseract：Apache-2.0（经 Homebrew 以独立进程调用，不与本应用静态链接）
- 若公开发布，请在页面注明引擎来源并遵守各上游许可证。

## 8. 已知限制 / Roadmap

- [ ] 扫描质量极差（歪斜>10°、低对比）时识别率有限——可开启「自动纠偏/去噪」改善
- [ ] 中文繁体/竖排依赖 `chi_tra`/`*_vert` 语言包（`setup.sh` 可扩展）
- [ ] 可选：监视文件夹自动 OCR、PDF/A-3、封面缩略图预览
