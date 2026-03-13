import Foundation
import OSLog
import Combine
import AppKit
import Vision

// swiftlint:disable type_body_length cyclomatic_complexity
@MainActor
class ClipboardViewModel: ObservableObject {
    @Published var items: [ClipboardItem] = [] {
        didSet {
            LogManager.shared.write("[ViewModel] items updated: count=\(items.count)")
        }
    }
    @Published var searchText: String = ""
    @Published var isLoading: Bool = false
    @Published var selectedItem: ClipboardItem?
    @Published var errorMessage: String?
    // iCloud 同步可视状态
    @Published var iCloudSyncInProgress: Bool = false
    @Published var iCloudSyncPhase: String?
    @Published var lastICloudBackupPath: String?
    
    var isMonitoring: Bool {
        monitor.isMonitoring
    }
    
    let monitor: ClipboardMonitor
    private let database: DatabaseManager
    private let log = Logger(subsystem: "com.clipflow.app", category: "ViewModel")
    private let backupManager = BackupManager.shared
    
    private var cancellables = Set<AnyCancellable>()
    
    init(monitor: ClipboardMonitor = ClipboardMonitor(),
         database: DatabaseManager = DatabaseManager()) {
        let startTime = CFAbsoluteTimeGetCurrent()
        LogManager.shared.write("[ViewModel] Start init")
        self.monitor = monitor
        self.database = database
        
        setupBindings()
        loadInitialData()
        // 应用启动后，如已开启 iCloud 备份，自动尝试一次备份，便于用户看到进度/结果
        if isICloudBackupEnabled {
            onICloudBackupToggle(true)
        }
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        LogManager.shared.write("[ViewModel] Init complete. Duration: \(String(format: "%.3f", duration))s")
    }
    
    private func setupBindings() {
        monitor.$lastItem
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in
                self?.handleNewItem(item)
            }
            .store(in: &cancellables)
        
        $searchText
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] query in
                self?.searchItems(query: query)
            }
            .store(in: &cancellables)
    }
    
    private func loadInitialData() {
        let startTime = CFAbsoluteTimeGetCurrent()
        LogManager.shared.write("[ViewModel] Start loading initial data")
        isLoading = true
        database.fetchItems(limit: 100) { [weak self] fetchedItems in
            let fetchDuration = CFAbsoluteTimeGetCurrent() - startTime
            LogManager.shared.write("[ViewModel] Database fetch returned. Duration: \(String(format: "%.3f", fetchDuration))s")
            
            let dedupStart = CFAbsoluteTimeGetCurrent()
            self?.items = Self.deduplicateByHashKeepingLatest(fetchedItems)
            let dedupDuration = CFAbsoluteTimeGetCurrent() - dedupStart
            
            self?.isLoading = false
            
            let totalDuration = CFAbsoluteTimeGetCurrent() - startTime
            LogManager.shared.write("[ViewModel] Initial data loaded. Dedup: \(String(format: "%.3f", dedupDuration))s, Total: \(String(format: "%.3f", totalDuration))s")
        }
    }
    
    private func handleNewItem(_ item: ClipboardItem) {
        if let existingIndex = items.firstIndex(where: { $0.contentHash == item.contentHash }) {
            items.remove(at: existingIndex)
        }
        
        items.insert(item, at: 0)
        
        database.saveItem(item) { [weak self] success in
            guard let self = self else { return }
            if !success {
                self.errorMessage = "Failed to save item"
            }
            // 备份到 iCloud（若开启）
            if success, UserDefaults.standard.bool(forKey: "clipflow.backup.icloud") {
                self.backupManager.backupDatabase(dbURL: self.database.dbFileURL)
            }
        }
        
        performOCR(for: item)
    }

    private func performOCR(for item: ClipboardItem) {
        guard UserDefaults.standard.bool(forKey: "clipflow.ocr.enabled"),
              item.type == .image, let data = item.imageData else { return }
              
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.log.debug("[OCR] 开始识别，id=\(item.id.uuidString)")
            LogManager.shared.write("[OCR] start id=\(item.id.uuidString)")
            let mgr = OCRManager.shared
            let provider = mgr.resolveProviderWithLog()
            
            if let text = provider.recognizeText(from: data), !text.isEmpty {
                self.handleOCRSuccess(item: item, text: text)
            } else {
                self.log.warning("[OCR] 识别为空或失败，id=\(item.id.uuidString)")
                LogManager.shared.write("[OCR] empty or failed id=\(item.id.uuidString)")
                DispatchQueue.main.async { self.errorMessage = "OCR 未识别到文本（请检查图片清晰度）" }
            }
        }
    }

    private func handleOCRSuccess(item: ClipboardItem, text: String) {
        let updated = ClipboardItem(
            id: item.id, timestamp: item.timestamp, type: item.type,
            contentHash: item.contentHash, textContent: item.textContent,
            imageData: item.imageData, fileURLs: item.fileURLs, url: item.url,
            rtfData: item.rtfData, pdfData: item.pdfData, htmlContent: item.htmlContent,
            rawData: item.rawData, ocrText: text, sourceApp: item.sourceApp
        )
        DispatchQueue.main.async {
            if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                self.items[idx] = updated
            }
            self.database.saveItem(updated) { success in
                if !success { self.errorMessage = "Failed to save OCR result" }
                if success, UserDefaults.standard.bool(forKey: "clipflow.backup.icloud") {
                    self.backupManager.backupDatabase(dbURL: self.database.dbFileURL)
                }
            }
            let preview = text.count > 30 ? String(text.prefix(30)) + "…" : text
            self.errorMessage = "OCR 识别完成：\(preview)"
        }
        LogManager.shared.write("[OCR] success id=\(item.id.uuidString) len=\(text.count)")
    }
    
    private func searchItems(query: String) {
        if query.isEmpty {
            loadInitialData()
            return
        }
        
        isLoading = true
        database.searchItems(query: query, limit: 100) { [weak self] fetchedItems in
            self?.items = Self.deduplicateByHashKeepingLatest(fetchedItems)
            self?.isLoading = false
        }
    }
    
    func startMonitoring() {
        monitor.startMonitoring()
    }
    
    func stopMonitoring() {
        monitor.stopMonitoring()
    }
    
    func copyItem(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        
        switch item.type {
        case .text:
            if let text = item.textContent {
                pasteboard.setString(text, forType: .string)
            }
        case .image:
            if let imageData = item.imageData, let image = NSImage(data: imageData) {
                pasteboard.writeObjects([image])
            }
        case .file:
            if let urls = item.fileURLs {
                pasteboard.writeObjects(urls as [NSURL])
            }
        case .url:
            if let url = item.url {
                pasteboard.setString(url.absoluteString, forType: .URL)
            }
        case .rtf:
            if let rtfData = item.rtfData {
                pasteboard.setData(rtfData, forType: .rtf)
            }
        case .pdf:
            if let pdfData = item.pdfData {
                pasteboard.setData(pdfData, forType: .pdf)
            }
        case .html:
            if let html = item.htmlContent {
                pasteboard.setString(html, forType: .html)
            }
        case .other:
            if let rawData = item.rawData {
                let dataType = NSPasteboard.PasteboardType(rawValue: "public.data")
                pasteboard.setData(rawData, forType: dataType)
            }
        }
    }
    
    // 设置项便于 UI 绑定（使用 UserDefaults 简化持久化）
    var isOCREnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "clipflow.ocr.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "clipflow.ocr.enabled") }
    }
    
    var isICloudBackupEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "clipflow.backup.icloud") }
        set { UserDefaults.standard.set(newValue, forKey: "clipflow.backup.icloud") }
    }
    
    func deleteItem(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        database.deleteItem(item) { [weak self] success in
            if !success {
                self?.errorMessage = "Failed to delete item"
                self?.loadInitialData()
            }
        }
    }
    
    func clearAll() {
        items.removeAll()
        database.clearAll { [weak self] success in
            if !success {
                self?.errorMessage = "Failed to clear history"
                self?.loadInitialData()
            }
        }
    }
    
    func refresh() {
        loadInitialData()
    }

    // iCloud 开关切换时立即验证容器并尝试备份一次数据库，给到可见反馈
    func onICloudBackupToggle(_ enabled: Bool) {
        guard enabled else {
            // 关闭 iCloud：立刻清理进度显示并隐藏状态栏
            iCloudSyncInProgress = false
            iCloudSyncPhase = nil
            lastICloudBackupPath = nil
            return
        }
        // 展示可视进度
        iCloudSyncInProgress = true
        iCloudSyncPhase = "检查容器…"
        backupManager.backupDatabase(dbURL: database.dbFileURL, progress: { [weak self] phase in
            DispatchQueue.main.async { self?.iCloudSyncPhase = phase }
        }, completion: { [weak self] success, path in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.iCloudSyncInProgress = false
                self.iCloudSyncPhase = nil
                if success {
                    self.lastICloudBackupPath = path
                    LogManager.shared.write("[iCloud] backup triggered via toggle -> \(path)")
                    self.errorMessage = "已备份到 iCloud：\(path)"
                } else if path == "Merged" || path == "Disabled" {
                    // 被合并或未启用，不做任何提示
                } else {
                    self.errorMessage = "iCloud 容器不可用：请在系统设置登录 iCloud 并启用 iCloud Drive"
                }
            }
        })
    }

    // 手动触发一次 iCloud 备份（UI 显式按钮）
    func syncICloudNow() {
        guard isICloudBackupEnabled else {
            self.errorMessage = "请先开启 iCloud Backup 再执行同步"
            return
        }
        onICloudBackupToggle(true)
    }

    // iCloud 容器可用性（用于状态栏展示）
    var iCloudContainerPathDescription: String? {
        backupManager.containerPathDescription()
    }
    var iCloudContainerAvailable: Bool {
        backupManager.containerPathDescription() != nil
    }

    // 诊断 iCloud：检查登录、容器与写权限
    func diagnoseICloud() {
        iCloudSyncInProgress = true
        iCloudSyncPhase = "诊断：检查登录状态…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var report: [String] = []
            let fm = FileManager.default
            if fm.ubiquityIdentityToken == nil {
                report.append("未登录 iCloud（identityToken=nil）")
                LogManager.shared.write("[iCloud] diagnose: identityToken is nil")
                DispatchQueue.main.async {
                    self.iCloudSyncInProgress = false
                    self.iCloudSyncPhase = nil
                    self.errorMessage = "未登录 iCloud 或未启用 iCloud Drive"
                }
                return
            } else {
                report.append("已登录 iCloud")
            }
            DispatchQueue.main.async { self.iCloudSyncPhase = "诊断：解析容器…" }
            let containerPath = self.backupManager.containerPathDescription() ?? "<nil>"
            report.append("容器路径：\(containerPath)")
            guard let base = self.backupManager.containerPathDescription().flatMap({ URL(fileURLWithPath: $0) }) else {
                LogManager.shared.write("[iCloud] diagnose: ubiquityURL is nil")
                DispatchQueue.main.async {
                    self.iCloudSyncInProgress = false
                    self.iCloudSyncPhase = nil
                    self.errorMessage = "未检测到 iCloud 容器（请启用 iCloud Drive 并重启应用）"
                }
                return
            }
            DispatchQueue.main.async { self.iCloudSyncPhase = "诊断：写入测试文件…" }
            let testDir = base.appendingPathComponent("db")
            let testFile = testDir.appendingPathComponent(".diag_\(UUID().uuidString).txt")
            try? fm.createDirectory(at: testDir, withIntermediateDirectories: true)
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var err: NSError?
            coordinator.coordinate(writingItemAt: testFile, options: .forReplacing, error: &err) { url in
                _ = try? Data("ping".utf8).write(to: url)
            }
            let ok = fm.fileExists(atPath: testFile.path)
            report.append("写入测试：\(ok ? "成功" : "失败") -> \(testFile.path)")
            LogManager.shared.write("[iCloud] diagnose: write test \(ok ? "ok" : "failed") -> \(testFile.path)")
            DispatchQueue.main.async {
                self.iCloudSyncInProgress = false
                self.iCloudSyncPhase = nil
                self.errorMessage = ok ? "iCloud 容器可用，已写入测试文件" : "iCloud 容器不可写，请检查系统设置"
                if ok { self.lastICloudBackupPath = testFile.deletingLastPathComponent().path }
            }
        }
    }

    // 显式触发对单条图片的 OCR
    func runOCR(on item: ClipboardItem) {
        guard item.type == .image, let data = item.imageData else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let mgr = OCRManager.shared
            let provider = mgr.resolveProviderWithLog()
            
            if let text = provider.recognizeText(from: data), !text.isEmpty {
                let updated = ClipboardItem(
                    id: item.id,
                    timestamp: item.timestamp,
                    type: item.type,
                    contentHash: item.contentHash,
                    textContent: item.textContent,
                    imageData: item.imageData,
                    fileURLs: item.fileURLs,
                    url: item.url,
                    rtfData: item.rtfData,
                    pdfData: item.pdfData,
                    htmlContent: item.htmlContent,
                    rawData: item.rawData,
                    ocrText: text,
                    sourceApp: item.sourceApp
                )
                DispatchQueue.main.async {
                    if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                        self.items[idx] = updated
                    }
                    self.database.saveItem(updated) { success in
                        if !success { self.errorMessage = "Failed to save OCR result" }
                        if success, UserDefaults.standard.bool(forKey: "clipflow.backup.icloud") {
                            self.backupManager.backupDatabase(dbURL: self.database.dbFileURL)
                        }
                    }
                    // 给出可见成功反馈（展示前 30 字符）
                    let preview = text.count > 30 ? String(text.prefix(30)) + "…" : text
                    self.errorMessage = "OCR 识别完成：\(preview)"
                }
                LogManager.shared.write("[OCR] manual: success id=\(item.id.uuidString) len=\(text.count)")
            } else {
                LogManager.shared.write("[OCR] manual: empty or failed id=\(item.id.uuidString)")
                DispatchQueue.main.async { self.errorMessage = "OCR 未识别到文本或执行失败（查看控制台日志）" }
            }
        }
    }

// MARK: - Deep Modules (in-file for simplicity of learning project)

protocol OCRProvider {
    func recognizeText(from imageData: Data) -> String?
}

// 使用 macOS 内置 Vision 框架的本地 OCR 提供器
final class VisionOCRProvider: OCRProvider {
    private let languages: [String]
    init(languages: [String]) { self.languages = languages }
    func recognizeText(from imageData: Data) -> String? {
        guard let nsImage = NSImage(data: imageData),
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage else { return nil }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        if !languages.isEmpty { req.recognitionLanguages = languages }
        do {
            try handler.perform([req])
            let obs = req.results as? [VNRecognizedTextObservation] ?? []
            let lines = obs.compactMap { $0.topCandidates(1).first?.string }.filter { !$0.isEmpty }
            return lines.isEmpty ? nil : lines.joined(separator: " ")
        } catch { return nil }
    }
}

final class OCRManager {
    static let shared = OCRManager(); private init() {}
    
    func resolveProvider() -> OCRProvider {
        let langs = (UserDefaults.standard.string(forKey: "clipflow.ocr.langs") ?? "zh-Hans,en-US")
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        return VisionOCRProvider(languages: langs)
    }
    
    func resolveProviderWithLog() -> OCRProvider {
        let langs = (UserDefaults.standard.string(forKey: "clipflow.ocr.langs") ?? "zh-Hans,en-US")
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        LogManager.shared.write("[OCR] using engine: vision langs=\(langs.joined(separator: ","))")
        return VisionOCRProvider(languages: langs)
    }
}

final class BackupManager {
    // 采用 iCloud Ubiquity 容器 + NSFileCoordinator，遵循正规 iCloud Documents 流程
    static let shared = BackupManager(); private init() {}
    private var enabled: Bool { UserDefaults.standard.bool(forKey: "clipflow.backup.icloud") }
    private let containerId = "iCloud.com.clipflow.app"
    private var ubiquityURL: URL? {
        // 优先显式容器，其次回退默认容器
        let fm = FileManager.default
        let base = fm.url(forUbiquityContainerIdentifier: containerId)
            ?? fm.url(forUbiquityContainerIdentifier: nil)
        return base?.appendingPathComponent("Documents/ClipFlow")
    }
    private var throttleTimer: Timer?
    private var pendingDBURL: URL?
    func backupJSON(for id: UUID) {
        guard enabled else { return }
        let src = itemsDir().appendingPathComponent("\(id.uuidString).json")
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        guard let dstDir = ubiquityURL?.appendingPathComponent("items") else { return }
        try? FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)
        let dst = dstDir.appendingPathComponent("\(id.uuidString).json")
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: dst, options: .forReplacing, error: &coordError) { url in
            // 优先使用 setUbiquitous 将文件纳入 iCloud 管理；失败则回退为复制
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
                // 先写到一个临时位置，再迁移到 iCloud（更符合流程）
                let tmp = url.deletingLastPathComponent().appendingPathComponent(".tmp_\(UUID().uuidString).json")
                try? FileManager.default.removeItem(at: tmp)
                try FileManager.default.copyItem(at: src, to: tmp)
                // 将临时文件迁移为 iCloud 文档
                do {
                    try FileManager.default.setUbiquitous(true, itemAt: tmp, destinationURL: url)
                } catch {
                    // 回退为直接写入容器
                    try? FileManager.default.removeItem(at: url)
                    try? FileManager.default.copyItem(at: src, to: url)
                }
            } catch {
                // 回退策略：直接复制进容器
                _ = try? FileManager.default.removeItem(at: url)
                _ = try? FileManager.default.copyItem(at: src, to: url)
            }
        }
        // 若协调失败，忽略（常见于未登录 iCloud 或容器不可用）
    }

    private var pendingCompletion: ((Bool, String) -> Void)?

    // 备份数据库文件（duckdb/sqlite）。为了避免高频复制，做 2 秒节流合并。
    func backupDatabase(dbURL: URL, progress: ((String) -> Void)? = nil, completion: ((Bool, String) -> Void)? = nil) {
        guard enabled else { completion?(false, "Disabled"); return }
        
        // 如果有正在等待的 Timer，说明之前的请求被合并了
        if throttleTimer != nil {
            pendingCompletion?(false, "Merged")
        }
        
        pendingDBURL = dbURL
        pendingCompletion = completion
        
        DispatchQueue.main.async {
            self.throttleTimer?.invalidate()
            self.throttleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                self?.throttleTimer = nil
                progress?("准备备份…")
                let comp = self?.pendingCompletion
                self?.pendingCompletion = nil
                
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    self?.performBackupDatabase(progress: progress, completion: comp)
                }
            }
        }
    }

    private func performBackupDatabase(progress: ((String) -> Void)? = nil, completion: ((Bool, String) -> Void)? = nil) {
        guard let src = pendingDBURL else { completion?(false, ""); return }
        pendingDBURL = nil
        guard FileManager.default.fileExists(atPath: src.path) else { completion?(false, ""); return }
        // 快速权限/登录判断：未登录 iCloud 时 identityToken 为空，直接失败并提示
        if FileManager.default.ubiquityIdentityToken == nil {
            LogManager.shared.write("[iCloud] identityToken is nil (not signed in)")
            completion?(false, "")
            return
        }
        progress?("检查容器…")
        var dstDirOpt = ubiquityURL?.appendingPathComponent("db")
        if dstDirOpt == nil {
            LogManager.shared.write("[iCloud] explicit container unavailable, trying default…")
            // 再尝试一次默认容器
            if let def = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents/ClipFlow/db") {
                dstDirOpt = def
            }
        }
        guard let dstDir = dstDirOpt else {
            LogManager.shared.write("[iCloud] ubiquity container unavailable (both explicit & default)")
            completion?(false, "")
            return
        }
        try? FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)
        let dst = dstDir.appendingPathComponent(src.lastPathComponent)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?
        coordinator.coordinate(writingItemAt: dst, options: .forReplacing, error: &error) { url in
            progress?("复制文件…")
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
                let tmp = url.deletingLastPathComponent().appendingPathComponent(".tmp_\(UUID().uuidString)_\(src.lastPathComponent)")
                try? FileManager.default.removeItem(at: tmp)
                try FileManager.default.copyItem(at: src, to: tmp)
                do {
                    progress?("迁移至 iCloud…")
                    try FileManager.default.setUbiquitous(true, itemAt: tmp, destinationURL: url)
                    LogManager.shared.write("[iCloud] backup db success -> \(url.path)")
                    completion?(true, url.path)
                } catch {
                    progress?("容器不可用，尝试直接写入…")
                    try? FileManager.default.removeItem(at: url)
                    try? FileManager.default.copyItem(at: src, to: url)
                    LogManager.shared.write("[iCloud] fallback copy db -> \(url.path)")
                    completion?(true, url.path)
                }
            } catch {
                _ = try? FileManager.default.removeItem(at: url)
                _ = try? FileManager.default.copyItem(at: src, to: url)
                LogManager.shared.write("[iCloud] exception fallback copy db -> \(url.path)")
                completion?(true, url.path)
            }
        }
        if let error { LogManager.shared.write("[iCloud] coordinator error: \(error.localizedDescription)") }
    }
    // 供 UI 检查容器可用性与路径
    func containerPathDescription() -> String? {
        ubiquityURL?.path
    }
    private func itemsDir() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            FileManager.default.temporaryDirectory.appendingPathComponent("com.clipflow.app")
        return appSupport.appendingPathComponent("ClipFlow/items")
    }
}
}

// MARK: - Helpers
extension ClipboardViewModel {
    static func deduplicateByHashKeepingLatest(_ arr: [ClipboardItem]) -> [ClipboardItem] {
        var map: [String: ClipboardItem] = [:]
        for item in arr {
            if let exist = map[item.contentHash] {
                if item.timestamp > exist.timestamp {
                    map[item.contentHash] = item
                }
            } else {
                map[item.contentHash] = item
            }
        }
        // 维持时间逆序
        return map.values.sorted { $0.timestamp > $1.timestamp }
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = self.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// 简易文件日志器：~/Library/Logs/ClipFlow/clipflow.log（5MB 滚动）
final class LogManager {
    static let shared = LogManager()
    private let queue = DispatchQueue(label: "com.clipflow.log", qos: .utility)
    private let fileURL: URL
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()
    private init() {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ??
            FileManager.default.temporaryDirectory
        let logsDir = docsDir.appendingPathComponent("ClipFlow/Logs")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        fileURL = logsDir.appendingPathComponent("clipflow.log")
    }
    func write(_ message: String) {
        let ts = dateFormatter.string(from: Date())
        let line = "[\(ts)] \(message)\n"
        queue.async {
            let data = Data(line.utf8)
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: self.fileURL.path) {
                if let handle = try? FileHandle(forWritingTo: self.fileURL) {
                    defer { try? handle.close() }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else { try? data.write(to: self.fileURL) }
            
            self.rotateLogIfNeeded()
        }
    }
    
    private func rotateLogIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: self.fileURL.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue > 5 * 1024 * 1024,
              let content = try? Data(contentsOf: self.fileURL),
              content.count > 1024 * 1024 else { return }
              
        let tail = content.suffix(1024 * 1024)
        try? tail.write(to: self.fileURL, options: .atomic)
    }
    func logPath() -> String { fileURL.path }
}