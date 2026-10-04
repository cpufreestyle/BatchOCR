//
//  BatchOCR — 批量 PDF OCR（GUI + CLI 双模式）
//
//  以开源 OCRmyPDF（MPL-2.0）+ Tesseract（Apache-2.0）为识别引擎，
//  在其上补齐付费软件（Nitro PDF Pro / ABBYY FineReader）才有的
//  Mac 批量图形界面：拖拽入列、参数配置、进度展示、结果校验。
//

import AppKit
import PDFKit
import CoreText
import UniformTypeIdentifiers

// MARK: - 设置

struct OCRSettings {
    enum Mode: Int, CaseIterable {
        case skipText = 0   // 跳过已有文字层的页面（安全默认）
        case redoOcr  = 1   // 重做已有文字层
        case forceOcr = 2   // 强制整页栅格化后重新识别

        var flag: String {
            switch self {
            case .skipText: return "--skip-text"
            case .redoOcr:  return "--redo-ocr"
            case .forceOcr: return "--force-ocr"
            }
        }
        var label: String {
            switch self {
            case .skipText: return "跳过已有文字层（推荐）"
            case .redoOcr:  return "重做已有文字层"
            case .forceOcr: return "强制整页重新识别"
            }
        }
    }

    var languages = "eng"
    var mode: Mode = .skipText
    var deskew = false
    var clean = false
    var rotatePages = false
    var pdfa = false
    var jobs = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
    var outputDir: URL?

    /// 允许的并行度范围：GUI 与 CLI 共用同一约束。
    static let jobsRange = 1...16
}

// MARK: - 引擎定位

enum Engine {
    static func locate(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/opt/homebrew/bin"
        for dir in env.split(separator: ":") {
            let full = (String(dir) as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        for fixed in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        where FileManager.default.isExecutableFile(atPath: fixed) { return fixed }
        return nil
    }

    static var ocrmypdfPath: String? { locate("ocrmypdf") }
    static var tesseractPath: String? { locate("tesseract") }

    static func unavailableReason() -> String? {
        if ocrmypdfPath == nil { return "未找到 ocrmypdf 引擎。请先运行：brew install ocrmypdf" }
        if tesseractPath == nil { return "未找到 tesseract。请先运行：brew install ocrmypdf" }
        return nil
    }

    static func installedLanguages() -> [String] {
        guard let bin = tesseractPath else { return [] }
        let out = runCommand(bin, ["--list-langs"])
        return out.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("List of") && $0 != "osd" }
            .sorted()
    }

    static func runCommand(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - PDF 检查（页数 / 文字层）

enum PDFCheck {
    static func info(_ url: URL) -> (pages: Int, chars: Int, sample: String) {
        guard let doc = PDFDocument(url: url) else { return (0, 0, "") }
        let s = doc.string ?? ""
        let sample = String(s.prefix(80))
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return (doc.pageCount, s.count, sample)
    }

    static func fileSize(_ url: URL) -> Int64 {
        let d = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (d?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

// MARK: - 识别结果

struct OCRResult {
    var ok: Bool
    var inputURL: URL
    var outputURL: URL?
    var outputBytes: Int64
    var pages: Int
    var chars: Int
    var message: String
}

// MARK: - OCR 执行（调用开源引擎）

enum OCRRunner {
    static let imageExts = ["png", "jpg", "jpeg", "tif", "tiff", "bmp"]
    static let acceptedExts = ["pdf"] + imageExts

    /// 递归收集目录下可处理的文件（含子目录、含图片），跳过隐藏文件；结果按路径排序。
    /// CLI 与 GUI「添加文件夹」共用，保证两处行为一致。
    static func collectInputs(in dir: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [URL] = []
        while let u = en.nextObject() as? URL {
            guard acceptedExts.contains(u.pathExtension.lowercased()) else { continue }
            let isFile = (try? u.resourceValues(forKeys: Set(keys)).isRegularFile) ?? false
            if isFile { found.append(u) }
        }
        return found.sorted { $0.path < $1.path }
    }

    static func resolveOutput(for input: URL, settings: OCRSettings) -> URL {
        let base = input.deletingPathExtension().lastPathComponent
        let dir = settings.outputDir ?? input.deletingLastPathComponent()
        var candidate = dir.appendingPathComponent(base + "_ocr.pdf")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)_ocr_\(n).pdf")
            n += 1
        }
        return candidate
    }

    static func convertImageToPDF(_ img: URL) -> URL? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".pdf")
        guard let sips = Engine.locate("sips") else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: sips)
        p.arguments = ["-s", "format", "pdf", img.path, "--out", tmp.path]
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? tmp : nil
    }

    static func ocrOne(input original: URL, settings: OCRSettings) -> OCRResult {
        func fail(_ msg: String) -> OCRResult {
            OCRResult(ok: false, inputURL: original, outputURL: nil,
                      outputBytes: 0, pages: 0, chars: 0, message: msg)
        }
        guard let bin = Engine.ocrmypdfPath else {
            return fail("找不到 ocrmypdf，请先运行 brew install ocrmypdf")
        }

        var input = original
        let ext = original.pathExtension.lowercased()
        if imageExts.contains(ext) {
            guard let tmp = convertImageToPDF(original) else { return fail("图片转 PDF 失败") }
            input = tmp
        }

        let output = resolveOutput(for: original, settings: settings)
        var args = [settings.mode.flag,
                    "--language", settings.languages,
                    "--jobs", String(settings.jobs),
                    "--output-type", settings.pdfa ? "pdfa" : "pdf"]
        if settings.deskew { args.append("--deskew") }
        if settings.clean { args.append("--clean") }
        if settings.rotatePages { args.append("--rotate-pages") }
        args += [input.path, output.path]

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return fail("无法启动 ocrmypdf：\(error.localizedDescription)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        if p.terminationStatus != 0 {
            let logText = String(data: data, encoding: .utf8) ?? ""
            let tail = logText.split(separator: "\n").suffix(4).joined(separator: " | ")
            return fail("ocrmypdf 退出码 \(p.terminationStatus)：\(String(tail.prefix(240)))")
        }

        let info = PDFCheck.info(output)
        guard info.pages > 0 else { return fail("输出文件无法解析") }
        return OCRResult(ok: true, inputURL: original, outputURL: output,
                         outputBytes: PDFCheck.fileSize(output),
                         pages: info.pages, chars: info.chars,
                         message: info.sample)
    }
}

// MARK: - 队列条目

struct DocItem {
    enum Status: String {
        case pending = "待处理", checking = "分析中…", running = "识别中…"
        case done = "完成", failed = "失败"
    }
    let url: URL
    var status: Status = .pending
    var pages = 0
    var hasTextLayer = false
    var resultURL: URL?
    var resultBytes: Int64 = 0
    var textChars = 0
    var note = ""
}

// MARK: - CLI 模式（供脚本化验证与命令行使用）

func runCLI(_ args: [String]) -> Int32 {
    let usage = """
    用法: BatchOCR --cli [选项] <文件.pdf|目录> ...
      --lang chi_sim+eng   识别语言，用 + 连接（默认 eng）
      --mode skip|redo|force   skip=跳过已有文字层, redo=重做, force=强制整页
      --deskew --clean --rotate   纠偏 / 去噪 / 自动旋转
      --pdfa               输出 PDF/A
      --jobs N             并行页数，范围 1-16（默认 CPU 数，超范围自动夹取）
      --out DIR            输出目录（默认：源目录 + _ocr 后缀）
    每行输出: [OK|FAIL]\\t文件\\t详情
    """
    var s = OCRSettings()
    var inputs: [String] = []
    var i = 0
    func fail(_ msg: String) -> Never {
        fputs("\(msg)\n\(usage)\n", stderr); exit(2)
    }
    /// 取下一个 token 作为选项取值。缺失、或下一个 token 又是一个 "--" 选项时抛错，
    /// 避免 `--out --deskew a.pdf` 把 `--deskew` 当成输出目录名。
    func value(_ name: String) -> String {
        guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
            fail("参数 \(name) 缺少取值（下一个 token 不是值）")
        }
        i += 1
        return args[i]
    }
    while i < args.count {
        let a = args[i]
        switch a {
        case "--lang":
            let v = value("--lang").trimmingCharacters(in: .whitespaces)
            if v.isEmpty { fail("参数 --lang 取值不能为空") }
            s.languages = v
        case "--mode":
            switch value("--mode") {
            case "skip": s.mode = .skipText
            case "redo": s.mode = .redoOcr
            case "force": s.mode = .forceOcr
            case let other: fail("未知的 --mode 取值：\(other)（可选 skip | redo | force）")
            }
        case "--jobs":
            let raw = value("--jobs")
            guard let n = Int(raw) else { fail("参数 --jobs 需要整数，收到：\(raw)") }
            s.jobs = max(OCRSettings.jobsRange.lowerBound, min(OCRSettings.jobsRange.upperBound, n))
        case "--out":
            var dir = value("--out")
            while dir.count > 1 && dir.hasSuffix("/") { dir.removeLast() }
            s.outputDir = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
                .resolvingSymlinksInPath()
        case "--deskew": s.deskew = true
        case "--clean": s.clean = true
        case "--rotate": s.rotatePages = true
        case "--pdfa": s.pdfa = true
        case "--help", "-h": print(usage); return 0
        default:
            if a.hasPrefix("-") { fail("未知参数：\(a)") }
            inputs.append((a as NSString).expandingTildeInPath)
        }
        i += 1
    }

    var files: [URL] = []
    for p in inputs {
        var isDir: ObjCBool = false
        let path = p
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            fputs("不存在：\(path)\n", stderr); return 2
        }
        if isDir.boolValue {
            files += OCRRunner.collectInputs(in: URL(fileURLWithPath: path))
        } else {
            files.append(URL(fileURLWithPath: path))
        }
    }
    guard !files.isEmpty else { print(usage); return 2 }

    if let reason = Engine.unavailableReason() {
        fputs("\(reason)\n", stderr); return 2
    }
    if let dir = s.outputDir {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    var okCount = 0, failCount = 0
    for f in files {
        fputs("→ \(f.lastPathComponent)\n", stderr)
        let r = OCRRunner.ocrOne(input: f, settings: s)
        if r.ok {
            okCount += 1
            print("[OK]\t\(f.lastPathComponent)\t\(r.outputURL?.path ?? "-")\tpages=\(r.pages)\tchars=\(r.chars)")
        } else {
            failCount += 1
            print("[FAIL]\t\(f.lastPathComponent)\t\(r.message.replacingOccurrences(of: "\t", with: " "))")
        }
    }
    fputs("batchocr：\(okCount) 成功，\(failCount) 失败\n", stderr)
    return failCount == 0 ? 0 : 1
}

// MARK: - GUI

final class DropView: NSView {
    var onFiles: (([URL]) -> Void)?
    var onLayout: (() -> Void)?

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return files(from: sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = files(from: sender) else { return false }
        onFiles?(urls)
        return true
    }

    private func files(from sender: NSDraggingInfo) -> [URL]? {
        guard let urls = sender.draggingPasteboard
            .readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else { return nil }
        let accepted = urls.filter {
            $0.isFileURL && OCRRunner.acceptedExts.contains($0.pathExtension.lowercased())
        }
        return accepted.isEmpty ? nil : accepted
    }
}

final class AppController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var window: NSWindow!
    private var items: [DocItem] = []
    private var isRunning = false
    private var settings = OCRSettings()
    private var lastOutputDir: URL?

    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let engineLabel = NSTextField(labelWithString: "")
    private var startButton: NSButton!
    private var addButton: NSButton!
    private var addFolderButton: NSButton!
    private var removeButton: NSButton!
    private var clearButton: NSButton!
    private var langCombo: NSComboBox!
    private var modePopup: NSPopUpButton!
    private var deskewCheck: NSButton!
    private var cleanCheck: NSButton!
    private var rotateCheck: NSButton!
    private var pdfaCheck: NSButton!
    private var jobsStepper: NSStepper!
    private var jobsLabel: NSTextField!
    private var outputPopup: NSPopUpButton!
    private var openFolderButton: NSButton!
    private var hintLabel: NSTextField!
    private var langTitle: NSTextField!
    private var modeTitle: NSTextField!
    private var outTitle: NSTextField!
    private let scroll = NSScrollView()

    private var outputDirURL: URL?

    // MARK: 悬停提示（复杂控件的一句话说明）

    private let langTip = "识别所用的语言。中文文档选 chi_sim+eng（中英混排），纯英文选 eng。"
        + "多个语言用 + 连接，语言越多识别越慢。"

    private var modeTip: String {
        "已有文字层的处理方式：\n"
            + "· 跳过已有文字层 — 已有文字页原样保留，只补没文字层的页（推荐）\n"
            + "· 重做已有文字层 — 在保留原文字的前提下重跑识别，修错误\n"
            + "· 强制整页重新识别 — 丢弃原文字层，整页重新识别（最慢，易出错）"
    }

    private var jobsTip: String {
        "同时处理的页数：数值越大越快，占用 CPU 越多。"
            + "范围 \(OCRSettings.jobsRange.lowerBound)–\(OCRSettings.jobsRange.upperBound)，默认按本机核心数。"
    }

    private var outputTip: String {
        "结果 PDF 的存放位置：\n"
            + "· 输出到原目录 — 与原文件同目录，文件名加 _ocr 后缀，不覆盖原文件\n"
            + "· 输出到指定文件夹 — 统一集中保存到你选择的文件夹"
    }

    private let statusTip = "队列概况：文件总数、已完成数与失败数。"

    // MARK: 窗口与布局

    func buildWindow() {
        let content = DropView(frame: NSRect(x: 0, y: 0, width: 820, height: 640))
        content.registerForDraggedTypes([.fileURL])
        content.onFiles = { [weak self] in self?.addURLs($0) }
        content.onLayout = { [weak self] in self?.layoutContent() }

        hintLabel = NSTextField(labelWithString:
            "把 PDF（或图片）拖到这里 — 批量 OCR 生成可搜索 PDF · 引擎：OCRmyPDF + Tesseract（开源）")
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor

        // 表格
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let ids: [(String, String, CGFloat)] = [
            ("name", "文件名", 250), ("pages", "页数", 52), ("orig", "原大小", 78),
            ("result", "结果大小", 84), ("status", "状态", 260),
        ]
        for (id, title, w) in ids {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = w
            col.minWidth = 40
            tableView.addTableColumn(col)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 26
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.toolTip = "队列列表：每个文件的页数、体积与识别状态。改好上方选项后点「开始 OCR」批量处理。"
        scroll.documentView = tableView

        // 按钮行
        addButton = button("添加 PDF…", #selector(chooseFiles),
                           tip: "选择若干 PDF／图片加入队列。图片会自动转为 PDF 再识别。")
        addFolderButton = button("添加文件夹…", #selector(chooseFolder),
                                 tip: "选择文件夹，递归找出里面所有 PDF 与图片并加入队列（含子目录）。")
        removeButton = button("移除所选", #selector(removeSelected),
                              tip: "把选中条目移出列表，不会删除磁盘上的原文件。")
        clearButton = button("清空", #selector(clearAll),
                             tip: "清空整个列表。同样只影响列表，不碰原文件。")

        // 选项行 1：语言 / 模式
        langTitle = label("识别语言：", tip: langTip)
        langCombo = NSComboBox()
        langCombo.completes = true
        let langs = Engine.installedLanguages()
        langCombo.removeAllItems()
        langCombo.addItems(withObjectValues: langs)
        langCombo.stringValue = langs.contains("chi_sim") ? "chi_sim+eng" : "eng"
        langCombo.toolTip = langTip

        modeTitle = label("模式：", tip: modeTip)
        modePopup = NSPopUpButton()
        modePopup.addItems(withTitles: OCRSettings.Mode.allCases.map(\.label))
        modePopup.selectItem(at: 0)
        modePopup.toolTip = modeTip

        // 选项行 2：开关 / 并行
        deskewCheck = check("自动纠偏", tip: "识别前先摆正倾斜的扫描页。只在页面歪斜时勾选，正常文档不必开。")
        cleanCheck = check("去噪", tip: "抹掉扫描件的杂点与斑点，噪点多的复印件开启后识别更准。")
        rotateCheck = check("自动旋转", tip: "按文字方向把横倒的页面转正。扫描时页面放歪了就勾选。")
        pdfaCheck = check("输出 PDF/A", tip: "输出长期归档格式 PDF/A。适合存档，体积会略大；普通使用不必勾选。")
        jobsStepper = NSStepper()
        jobsStepper.minValue = Double(OCRSettings.jobsRange.lowerBound)
        jobsStepper.maxValue = Double(OCRSettings.jobsRange.upperBound)
        jobsStepper.doubleValue = Double(settings.jobs)
        jobsStepper.target = self
        jobsStepper.action = #selector(stepperChanged)
        jobsStepper.toolTip = jobsTip
        jobsLabel = label("并行 \(settings.jobs)")
        jobsLabel.toolTip = jobsTip

        // 选项行 3：输出
        outTitle = label("输出：", tip: outputTip)
        outputPopup = NSPopUpButton()
        outputPopup.addItems(withTitles: ["输出到原目录（加 _ocr 后缀）", "输出到指定文件夹…"])
        outputPopup.target = self
        outputPopup.action = #selector(outputChanged)
        outputPopup.toolTip = outputTip

        // 底部
        startButton = button("开始 OCR", #selector(startOCR),
                             tip: "对列表中所有未完成文件批量识别；处理期间界面会暂时锁定。")
        startButton.keyEquivalent = "\r"
        openFolderButton = button("打开输出文件夹", #selector(openFolder),
                                  tip: "在访达中打开最近一次的输出位置。")
        statusLabel.alignment = .right
        statusLabel.toolTip = statusTip

        engineLabel.font = .systemFont(ofSize: 10.5)
        engineLabel.textColor = .tertiaryLabelColor
        engineLabel.stringValue = "引擎：\(Engine.ocrmypdfPath ?? "未找到 ocrmypdf") · 语言包：\(langs.isEmpty ? "未知" : langs.joined(separator: " "))"

        for v: NSView in [hintLabel, scroll, addButton, addFolderButton, removeButton, clearButton,
                          langTitle, langCombo, modeTitle, modePopup,
                          deskewCheck, cleanCheck, rotateCheck, pdfaCheck, jobsStepper, jobsLabel,
                          outTitle, outputPopup,
                          startButton, openFolderButton, statusLabel, engineLabel] {
            content.addSubview(v)
        }

        let win = NSWindow(contentRect: content.bounds,
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "BatchOCR — 批量 PDF OCR（基于开源 OCRmyPDF）"
        win.contentView = content
        win.center()
        win.minSize = NSSize(width: 760, height: 600)
        window = win
        layoutContent()
        refreshControls()
        updateStatus()
    }

    /// 手动确定性布局（flipped 坐标，自上而下）
    func layoutContent() {
        guard let cv = window?.contentView else { return }
        let w = cv.bounds.width, h = cv.bounds.height
        hintLabel.frame = NSRect(x: 14, y: 10, width: w - 28, height: 18)
        let scrollH = max(140, h - 410)
        scroll.frame = NSRect(x: 14, y: 36, width: w - 28, height: scrollH)
        var y = 36 + scrollH + 12
        addButton.frame = NSRect(x: 14, y: y, width: 108, height: 26)
        addFolderButton.frame = NSRect(x: 130, y: y, width: 124, height: 26)
        removeButton.frame = NSRect(x: 262, y: y, width: 92, height: 26)
        clearButton.frame = NSRect(x: 362, y: y, width: 64, height: 26)
        y += 38
        langTitle.frame = NSRect(x: 14, y: y + 5, width: 68, height: 18)
        langCombo.frame = NSRect(x: 86, y: y, width: 190, height: 28)
        modeTitle.frame = NSRect(x: 294, y: y + 5, width: 42, height: 18)
        modePopup.frame = NSRect(x: 340, y: y, width: 214, height: 28)
        y += 40
        deskewCheck.frame = NSRect(x: 14, y: y + 2, width: 88, height: 22)
        cleanCheck.frame = NSRect(x: 108, y: y + 2, width: 62, height: 22)
        rotateCheck.frame = NSRect(x: 176, y: y + 2, width: 88, height: 22)
        pdfaCheck.frame = NSRect(x: 270, y: y + 2, width: 104, height: 22)
        jobsStepper.frame = NSRect(x: 388, y: y, width: 44, height: 26)
        jobsLabel.frame = NSRect(x: 438, y: y + 4, width: 62, height: 18)
        y += 38
        outTitle.frame = NSRect(x: 14, y: y + 5, width: 44, height: 18)
        outputPopup.frame = NSRect(x: 62, y: y, width: 264, height: 28)
        y += 42
        startButton.frame = NSRect(x: 14, y: y, width: 112, height: 32)
        openFolderButton.frame = NSRect(x: 134, y: y + 2, width: 136, height: 28)
        statusLabel.frame = NSRect(x: w - 334, y: y + 7, width: 320, height: 18)
        engineLabel.frame = NSRect(x: 14, y: y + 46, width: w - 28, height: 15)
    }

    private func label(_ t: String, tip: String? = nil) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.toolTip = tip
        return l
    }

    private func check(_ t: String, tip: String? = nil) -> NSButton {
        let b = NSButton(checkboxWithTitle: t, target: self, action: nil)
        b.toolTip = tip
        return b
    }

    private func button(_ title: String, _ action: Selector, tip: String? = nil) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.toolTip = tip
        return b
    }

    // MARK: 条目管理

    @objc private func chooseFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = [.pdf, .png, .jpeg, .tiff]
        guard p.runModal() == .OK else { return }
        addURLs(p.urls)
    }

    @objc private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        guard p.runModal() == .OK, let dir = p.url else { return }
        addURLs(OCRRunner.collectInputs(in: dir))
    }

    @objc private func removeSelected() {
        guard !isRunning else { return }
        let idx = tableView.selectedRowIndexes
        guard !idx.isEmpty else { return }
        items.remove(atOffsets: IndexSet(idx))
        reload()
        updateStatus()
    }

    @objc private func clearAll() {
        guard !isRunning else { return }
        items.removeAll()
        reload()
        updateStatus()
    }

    func addURLs(_ urls: [URL]) {
        guard !isRunning else { return }
        var added = false
        for u in urls {
            let path = u.resolvingSymlinksInPath().path
            guard !items.contains(where: { $0.url.path == path }) else { continue }
            items.append(DocItem(url: URL(fileURLWithPath: path)))
            added = true
        }
        if added {
            reload()
            updateStatus()
            // 后台预分析页数 / 文字层
            let snapshot = items
            DispatchQueue.global().async {
                for (i, item) in snapshot.enumerated() where item.status == .pending {
                    let info = PDFCheck.info(item.url)
                    DispatchQueue.main.async {
                        guard i < self.items.count, self.items[i].url == item.url,
                              self.items[i].status == .pending else { return }
                        self.items[i].pages = info.pages
                        self.items[i].hasTextLayer = info.chars > 50
                        self.tableView.reloadData(forRowIndexes: IndexSet([i]),
                                                  columnIndexes: IndexSet(integersIn: 0..<5))
                    }
                }
            }
        }
    }

    // MARK: 选项

    @objc private func stepperChanged() {
        settings.jobs = max(OCRSettings.jobsRange.lowerBound,
                            min(OCRSettings.jobsRange.upperBound, Int(jobsStepper.doubleValue)))
        jobsStepper.doubleValue = Double(settings.jobs)
        jobsLabel.stringValue = "并行 \(settings.jobs)"
    }

    @objc private func outputChanged() {
        if outputPopup.indexOfSelectedItem == 1 {
            let p = NSOpenPanel()
            p.canChooseDirectories = true
            p.canChooseFiles = false
            p.message = "OCR 结果将写入该文件夹"
            if p.runModal() == .OK, let dir = p.url {
                outputDirURL = dir
                outputPopup.item(at: 1)?.title = "输出：\(dir.lastPathComponent)/"
            } else {
                outputPopup.selectItem(at: 0)
                outputDirURL = nil
            }
        } else {
            outputDirURL = nil
        }
    }

    private func collectSettings() {
        settings.languages = langCombo.stringValue.isEmpty ? "eng" : langCombo.stringValue
        settings.mode = OCRSettings.Mode(rawValue: modePopup.indexOfSelectedItem) ?? .skipText
        settings.deskew = deskewCheck.state == .on
        settings.clean = cleanCheck.state == .on
        settings.rotatePages = rotateCheck.state == .on
        settings.pdfa = pdfaCheck.state == .on
        settings.outputDir = outputDirURL
    }

    // MARK: 执行

    @objc private func startOCR() {
        guard !isRunning, !items.isEmpty else { NSSound.beep(); return }
        if let reason = Engine.unavailableReason() { alert(reason); return }
        collectSettings()
        if let dir = settings.outputDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        isRunning = true
        refreshControls()

        let jobs: [(Int, URL)] = items.indices
            .filter { items[$0].status != .done }
            .map { ($0, items[$0].url) }
        let s = settings

        DispatchQueue.global().async {
            for (idx, url) in jobs {
                DispatchQueue.main.async {
                    guard idx < self.items.count, self.items[idx].url == url else { return }
                    self.items[idx].status = .running
                    self.tableView.reloadData()
                }
                let r = OCRRunner.ocrOne(input: url, settings: s)
                DispatchQueue.main.async {
                    guard idx < self.items.count, self.items[idx].url == url else { return }
                    if r.ok {
                        self.items[idx].status = .done
                        self.items[idx].resultURL = r.outputURL
                        self.items[idx].resultBytes = r.outputBytes
                        self.items[idx].pages = r.pages
                        self.items[idx].textChars = r.chars
                        self.items[idx].note = ""
                        self.lastOutputDir = r.outputURL?.deletingLastPathComponent()
                    } else {
                        self.items[idx].status = .failed
                        self.items[idx].note = r.message
                    }
                    self.tableView.reloadData()
                    self.updateStatus()
                }
            }
            DispatchQueue.main.async {
                self.isRunning = false
                self.refreshControls()
                self.updateStatus()
            }
        }
    }

    @objc private func openFolder() {
        let dir = settings.outputDir ?? lastOutputDir
        let url = dir ?? URL(fileURLWithPath: NSHomeDirectory())
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    // MARK: 状态

    private func refreshControls() {
        let engineOK = Engine.unavailableReason() == nil
        startButton.isEnabled = !isRunning && !items.isEmpty && engineOK
        addButton.isEnabled = !isRunning
        addFolderButton.isEnabled = !isRunning
        removeButton.isEnabled = !isRunning && !items.isEmpty
        clearButton.isEnabled = !isRunning && !items.isEmpty
        langCombo.isEnabled = !isRunning
        modePopup.isEnabled = !isRunning
        deskewCheck.isEnabled = !isRunning
        cleanCheck.isEnabled = !isRunning
        rotateCheck.isEnabled = !isRunning
        pdfaCheck.isEnabled = !isRunning
        outputPopup.isEnabled = !isRunning
    }

    private func updateStatus() {
        let done = items.filter { $0.status == .done }.count
        let failed = items.filter { $0.status == .failed }.count
        statusLabel.stringValue = items.isEmpty
            ? "尚无文件"
            : "共 \(items.count) 个文件 · 完成 \(done) · 失败 \(failed)"
        refreshControls()
    }

    private func reload() {
        tableView.reloadData()
        updateStatus()
    }

    private func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = "BatchOCR"
        a.informativeText = text
        a.runModal()
    }

    // MARK: NSTableView

    func numberOfRows(in _: NSTableView) -> Int { items.count }

    func tableView(_ _: NSTableView, objectValueFor column: NSTableColumn?, row: Int) -> Any? {
        guard row < items.count, let id = column?.identifier.rawValue else { return nil }
        let it = items[row]
        switch id {
        case "name": return it.url.lastPathComponent
        case "pages": return it.pages > 0 ? "\(it.pages)" : "—"
        case "orig": return ByteCountFormatter.string(fromByteCount: PDFCheck.fileSize(it.url), countStyle: .file)
        case "result":
            return it.resultBytes > 0
                ? ByteCountFormatter.string(fromByteCount: it.resultBytes, countStyle: .file) : "—"
        case "status":
            switch it.status {
            case .pending:
                return it.hasTextLayer ? "待处理 · 已有文字层" : "待处理"
            case .checking, .running:
                return it.status.rawValue
            case .done:
                var text = "完成 ✓ · \(it.textChars) 字符"
                let orig = PDFCheck.fileSize(it.url)
                if it.resultBytes > 0, orig > 0 {
                    let pct = Int((Double(orig - it.resultBytes) / Double(orig)) * 100)
                    text += pct >= 0 ? " · 体积 −\(pct)%" : " · 体积 +\(-pct)%"
                }
                return text
            case .failed:
                return "失败 · \(it.note)"
            }
        default: return nil
        }
    }
}

extension Array {
    mutating func remove(atOffsets offsets: IndexSet) {
        for i in offsets.sorted(by: >) where i < count { remove(at: i) }
    }
}

// MARK: - 入口

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    func applicationDidFinishLaunching(_: Notification) {
        controller.buildWindow()
        controller.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // 支持 `open -a BatchOCR xxx.pdf` / Finder 拖到 Dock 图标 → 直接入列
    func application(_ _: NSApplication, openFiles filenames: [String]) {
        controller.addURLs(filenames.map { URL(fileURLWithPath: $0) })
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }
}

func buildAppMenu() {
    let main = NSMenu()

    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "关于 BatchOCR", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "退出 BatchOCR", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu

    let editItem = NSMenuItem()
    main.addItem(editItem)
    let editMenu = NSMenu(title: "编辑")
    editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu

    NSApp.mainMenu = main
}

let cliArgs = CommandLine.arguments
if cliArgs.contains("--cli") {
    let code = runCLI(cliArgs.dropFirst().filter { $0 != "--cli" })
    exit(code)
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
buildAppMenu()
app.activate()
app.run()
