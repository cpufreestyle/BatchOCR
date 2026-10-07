# BatchOCR 规格说明（SPEC）

> 版本：1.0.0  ·  更新日期：2026-10-07  ·  状态：生效
> 本文档是 BatchOCR 的**行为契约**。任何改动若与本文档冲突，必须同步更新本文档并重启 harness 验证。
> 自动验证入口：`python3 test/harness.py`（逐条对应下文的 `C-*` / `S-*` 编号）。

---

## 1. 定位与范围

BatchOCR 是把扫描件/图片型 PDF **批量**转成**可搜索 PDF** 的 macOS 原生应用（GUI + CLI 双模式）。
识别引擎为外部开源程序 **OCRmyPDF + Tesseract**（经 Homebrew 安装，独立进程调用，不静态链接）。

范围内：批量队列、参数映射、结果校验、CLI 自动化接口、GUI 交互契约。
范围外：OCR 识别质量本身（由 Tesseract 决定）、引擎依赖的安装（见 `setup.sh`）。

## 2. 版本与产物

| 编号 | 契约 | 验证 |
| --- | --- | --- |
| S-01 | 版本号在 `Sources/main.swift`（`batchOCRVersion`）与 `resources/Info.plist`（`CFBundleShortVersionString`）中一致 | harness A1 |
| S-02 | `./build.sh` 产出 `build/BatchOCR.app`（含可执行文件与 Info.plist）与 `build/sample_tool` | harness A2 |
| S-03 | 最低系统版本 `LSMinimumSystemVersion = 14.0`；声明 PDF 与图片文档类型 | harness A3 |

版本号变更规则：改版本时**同时**修改主程序常量与 Info.plist，harness A1 会拦截漂移。

## 3. CLI 契约（`--cli`）

### 3.1 选项

| 选项 | 取值 | 语义 | 验证 |
| --- | --- | --- | --- |
| `--lang L` | 非空字符串 | Tesseract 语言，`+` 连接多语言；空值报错 | C-B6 |
| `--mode M` | `skip`\|`redo`\|`force` | 已有文字层处理策略；其它值报错 | C-B5 |
| `--jobs N` | 整数 | 并行页数，**夹取到 1...16**；非整数报错 | C-B7/C-B8 |
| `--deskew` / `--clean` / `--rotate` | 无 | 纠偏 / 去噪 / 自动旋转 | C-D1 |
| `--pdfa` | 无 | 输出 PDF/A 归档格式 | C-C3 |
| `--out DIR` | 路径 | 输出目录；**自动创建**；展开 `~`；去尾斜杠 | C-B9/C-C3 |
| `--help` / `-h` | 无 | 打印用法，退出码 0 | C-B1 |
| `--version` / `-v` | 无 | 打印 `BatchOCR <版本>`，退出码 0 | C-B2 |

取值守卫：选项后紧跟的 token 若以 `--` 开头，视为取值缺失 → 报错退出 2（避免 `--out --deskew a.pdf` 把 `--deskew` 当目录名）。见 C-B9。

### 3.2 输入与退出码

| 编号 | 契约 | 验证 |
| --- | --- | --- |
| S-10 | 位置参数为文件或目录；目录**递归**收集 PDF 与图片（png/jpg/jpeg/tif/tiff/bmp），忽略隐藏文件与非目标扩展名；报告的输出路径始终为绝对路径 | C-C4/C-C5 |
| S-11 | 以 `-` 开头的 token：磁盘上存在同名文件时按文件输入接受，并**补 `./` 前缀**后传给引擎（避免被 ocrmypdf 当作选项）；不存在时 → 报错 `未知参数：…`，退出码 2 | C-B3/C-B4/C-B12 |
| S-12 | 输入不存在 → 报错 `不存在：…`，退出码 2 | C-B11 |
| S-13 | 无有效输入 → 打印用法，退出码 2 | C-B10 |
| S-14 | 引擎缺失（找不到 ocrmypdf/tesseract）→ 报错，退出码 2 | 手动（卸载引擎场景） |

退出码：`0` 全部成功；`1` 有文件识别失败；`2` 用法/参数/环境错误。

### 3.3 输出格式

stdout 每文件一行（制表符分隔）：

```
[OK]\t<源文件名>\t<输出路径>\tpages=N\tchars=M
[FAIL]\t<源文件名>\t<失败原因>
```

stderr：处理进度 `→ <文件名>`，末尾汇总 `batchocr：X 成功，Y 失败`。

输出文件名：默认 `<原名>_ocr.pdf`；目标已存在时追加序号 `<原名>_ocr_2.pdf`、`_ocr_3.pdf`…（不覆盖）。见 C-C1/C-C2。

## 4. 识别与结果校验

| 编号 | 契约 | 验证 |
| --- | --- | --- |
| S-20 | 对无文字层的图片型 PDF，OCR 后输出可提取文字层（chars > 0） | C-D1/C-D2/C-D3 |
| S-21 | 输出页数与输入一致，且可被 PDFKit 重新解析 | C-D4 |
| S-22 | `--deskew --clean` 对倾斜 + 噪点样例仍能产出合格文字层 | C-D4 |
| S-23 | **确定性**：`sample_tool gen` 相同参数两次生成的样例**图像内容**逐像素一致（噪点使用固定随机种子）。原始文件字节不作要求 —— CGContext 会把生成时间写入 PDF 的 CreationDate/ID，字节必然每次不同。用 `sample_tool pixelhash` 校验渲染结果 | C-E1 |

## 5. GUI 不变量（人工 + 静态核查）

| 编号 | 契约 | 验证 |
| --- | --- | --- |
| S-30 | 布局用 flipped 坐标 + `layout()` 手动计算 frame（NSStackView 方案已废弃，不得回退） | harness F1 |
| S-31 | 冷启动时双击 PDF 不崩溃：`openFiles` 早于窗口构建时先缓存 URL，控件就绪后补入列 | harness F2 |
| S-32 | 从 Finder/Dock 启动时，OCR 子进程继承补全后的 PATH（含 Homebrew 目录），否则 ocrmypdf 找不到 tesseract | harness F3 |
| S-33 | 处理期间（isRunning）参数控件与队列操作按钮禁用 | 人工 |
| S-34 | 队列为空时显示拖拽提示浮层，有文件后隐藏 | 人工 |
| S-35 | 复杂控件具备悬停提示（toolTip） | 人工（AX help 核验） |

## 6. 依赖

- `ocrmypdf`（含 `tesseract`/`ghostscript`/`qpdf`），经 Homebrew：`brew install ocrmypdf`
- 中文语言包 `chi_sim`：`./setup.sh` 补齐（tessdata_fast）
- 构建：`swiftc`（`-swift-version 5`），无需 Xcode 工程

## 7. 变更流程

1. 改行为 → 先更新本文档对应条目（新增编号或修订）。
2. 改/加 harness 检查覆盖新条目。
3. `./build.sh && python3 test/harness.py` 通过后提交。
4. 提交信息用 Conventional Commits（`feat:` / `fix:` / `docs:` / `test:`）。
