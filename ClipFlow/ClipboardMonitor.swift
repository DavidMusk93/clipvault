import Foundation
import AppKit
import CommonCrypto
import ImageIO
import CoreGraphics

extension Notification.Name {
    static let clipFlowOCRReady = Notification.Name("ClipFlowOCRReady")
}

class ClipboardMonitor: ObservableObject {
    @Published var lastItem: ClipboardItem?
    @Published var isMonitoring = false
    
    private var timer: Timer?
    private var lastChangeCount: Int = 0
    /// While WKWebView archives, sites/WebKit may dirty NSPasteboard — absorb, don't spawn cards.
    private var suppressCaptureUntil: Date?
    private let pasteboard = NSPasteboard.general
    private let database: DatabaseManager?

    static weak var shared: ClipboardMonitor?
    
    private let monitorQueue = DispatchQueue(label: "com.clipflow.monitor", qos: .userInitiated)
    private let ocrQueue = DispatchQueue(label: "com.clipflow.strip-ocr", qos: .utility)
    
    init(database: DatabaseManager? = nil) {
        self.database = database
        lastChangeCount = pasteboard.changeCount
        ClipboardMonitor.shared = self
    }

    /// Swallow pasteboard mutations (archive WebView, programmatic writes).
    func suppressCapture(for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        if let cur = suppressCaptureUntil, cur > until {
            lastChangeCount = pasteboard.changeCount
            return
        }
        suppressCaptureUntil = until
        lastChangeCount = pasteboard.changeCount
    }

    func absorbPasteboardNow() {
        lastChangeCount = pasteboard.changeCount
    }
    
    func startMonitoring() {
        guard !isMonitoring else { return }
        
        isMonitoring = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
        scheduleStripOCRBackfill()
    }
    
    func stopMonitoring() {
        isMonitoring = false
        timer?.invalidate()
        timer = nil
    }
    
    private func checkPasteboard() {
        let currentChangeCount = pasteboard.changeCount
        if let until = suppressCaptureUntil {
            if Date() < until {
                lastChangeCount = currentChangeCount
                return
            }
            suppressCaptureUntil = nil
        }

        guard currentChangeCount != lastChangeCount else { return }
        
        lastChangeCount = currentChangeCount
        
        monitorQueue.async { [weak self] in
            guard let self = self, let item = self.createClipboardItem() else {
                return
            }
            
            // Local SQLite first; multi-device op-log via CloudDocsSyncService (not whole-db backup).
            self.database?.saveItemDetailed(item) { result in
                CloudDocsSyncService.shared?.recordLocalCapture(item: item, result: result)
                iCloudSyncManager.shared.syncItemToCloud(item)
                NotificationCenter.default.post(
                    name: Notification.Name("ClipFlowItemAdded"),
                    object: item
                )
                if case .inserted = result, item.type == .image {
                    self.scheduleOCR(hash: item.contentHash, persistId: item.id)
                }
            }

            DispatchQueue.main.async {
                self.lastItem = item
            }
        }
    }
    
    private func createClipboardItem() -> ClipboardItem? {
        let timestamp = Date()
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName

        if let item = createFileItem(timestamp: timestamp, sourceApp: sourceApp) { return item }
        if let item = createImageItem(timestamp: timestamp, sourceApp: sourceApp) { return item }
        if let item = createURLItem(timestamp: timestamp, sourceApp: sourceApp) { return item }
        if let item = createPDFItem(timestamp: timestamp, sourceApp: sourceApp) { return item }
        if let item = createRTFItem(timestamp: timestamp, sourceApp: sourceApp) { return item }
        if let item = createHTMLItem(timestamp: timestamp, sourceApp: sourceApp) { return item }
        if let item = createTextItem(timestamp: timestamp, sourceApp: sourceApp) { return item }
        if let item = createRawItem(timestamp: timestamp, sourceApp: sourceApp) { return item }

        return nil
    }

    private static let imageFileExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "tiff", "tif", "bmp"
    ]

    /// Feishu/Lark, Finder, and many apps put **image file URLs** on the pasteboard
    /// (public.file-url / NSFilenamesPboardType) instead of public.png/tiff.
    /// createClipboardItem prefers files over images, so without promotion those
    /// become type=file with path-only hash → UI "No preview" and no CAS blob/OCR.
    private func createFileItem(timestamp: Date, sourceApp: String?) -> ClipboardItem? {
        guard let fileURLs = getFileURLs(), !fileURLs.isEmpty else { return nil }

        let allImageFiles = fileURLs.allSatisfy {
            Self.imageFileExtensions.contains($0.pathExtension.lowercased())
        }
        if allImageFiles,
           let first = fileURLs.first,
           let rawData = try? Data(contentsOf: first),
           !rawData.isEmpty {
            let imageData = ImageStoragePolicy.compressForStorage(rawData) ?? normalizeToPNG(rawData) ?? rawData
            let hash = computeHash(for: imageData)
            return ClipboardItem(
                timestamp: timestamp, type: .image, contentHash: hash,
                imageData: imageData, fileURLs: fileURLs,
                ocrText: nil, sourceApp: sourceApp
            )
        }

        let hash = computeHash(for: fileURLs.map { $0.path }.joined())
        return ClipboardItem(
            timestamp: timestamp, type: .file, contentHash: hash,
            fileURLs: fileURLs, sourceApp: sourceApp
        )
    }

    private func createImageItem(timestamp: Date, sourceApp: String?) -> ClipboardItem? {
        guard let rawData = getImageData() else { return nil }
        // Strip screenshots scale by short edge (see ImageStoragePolicy).
        let imageData = ImageStoragePolicy.compressForStorage(rawData) ?? normalizeToPNG(rawData) ?? rawData
        let hash = computeHash(for: imageData)
        return ClipboardItem(
            timestamp: timestamp, type: .image, contentHash: hash,
            imageData: imageData, ocrText: nil, sourceApp: sourceApp
        )
    }

    private func scheduleOCR(hash: String, persistId: UUID) {
        ocrQueue.async { [weak self] in
            guard let self else { return }
            let data = self.database?.readBlobFile(hash: hash)
            guard let data, !data.isEmpty else { return }
            let t0 = Date()
            let text = StripOCR.recognize(data: data)
            let ms = Date().timeIntervalSince(t0) * 1000
            let n = text?.count ?? 0
            let pages = ImageStoragePolicy.pixelSize(of: data)
            print("[OCR] id=\(persistId.uuidString.prefix(8)) \(pages.map { "\($0.0)x\($0.1)" } ?? "?") chars=\(n) \(String(format: "%.0f", ms))ms")
            if let text {
                self.database?.updateOCR(id: persistId, text: text)
                NotificationCenter.default.post(name: .clipFlowOCRReady, object: persistId)
            }
        }
    }

    /// Re-run strip OCR for already-stored tall screenshots (derived field, not capture).
    private func scheduleStripOCRBackfill() {
        ocrQueue.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.database?.listImageHashes { refs in
                guard let self else { return }
                self.ocrQueue.async {
                    var n = 0
                    for ref in refs {
                        guard let data = self.database?.readBlobFile(hash: ref.hash), !data.isEmpty else { continue }
                        guard let size = ImageStoragePolicy.pixelSize(of: data) else { continue }
                        let short = min(size.0, size.1)
                        let long = max(size.0, size.1)
                        guard short >= 360, long >= 2400 else { continue }
                        let t0 = Date()
                        guard let text = StripOCR.recognize(data: data) else { continue }
                        let ms = Date().timeIntervalSince(t0) * 1000
                        print("[OCR] backfill id=\(ref.id.uuidString.prefix(8)) \(size.0)x\(size.1) chars=\(text.count) \(String(format: "%.0f", ms))ms")
                        self.database?.updateOCR(id: ref.id, text: text)
                        NotificationCenter.default.post(name: .clipFlowOCRReady, object: ref.id)
                        n += 1
                    }
                    if n > 0 {
                        print("[OCR] backfill done n=\(n)")
                    }
                }
            }
        }
    }

    private func normalizeToPNG(_ data: Data) -> Data? {
        if data.count >= 8, data[0] == 0x89, data[1] == 0x50, data[2] == 0x4E, data[3] == 0x47 {
            return data
        }
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let out = NSMutableData()
            if let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cgImage, nil)
                if CGImageDestinationFinalize(dest) {
                    return out as Data
                }
            }
        }
        if let image = NSImage(data: data),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        return nil
    }

    private func getImageData() -> Data? {
        // Prefer the largest pixel payload. Some apps put a PNG preview next to a full TIFF.
        let types: [NSPasteboard.PasteboardType] = [
            .png,
            .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic")
        ]
        var candidates: [Data] = []
        if let items = pasteboard.pasteboardItems {
            for item in items {
                for type in types {
                    if let data = item.data(forType: type), !data.isEmpty {
                        candidates.append(data)
                    }
                }
            }
        }
        if candidates.isEmpty {
            for type in types {
                if let data = pasteboard.data(forType: type), !data.isEmpty {
                    candidates.append(data)
                }
            }
        }
        if let best = ImageStoragePolicy.largestPayload(candidates) {
            return best
        }
        if let urls = getFileURLs(), let first = urls.first {
            let ext = first.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "webp", "gif", "heic", "tiff"].contains(ext),
               let fileData = try? Data(contentsOf: first) {
                return fileData
            }
        }
        // Last resort: NSImage may rasterize at preview DPI — only if nothing else worked.
        if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
           let tiff = image.tiffRepresentation {
            return tiff
        }
        return nil
    }

    private func createURLItem(timestamp: Date, sourceApp: String?) -> ClipboardItem? {
        guard let url = getURL() else { return nil }
        let hash = computeHash(for: url.absoluteString)
        return ClipboardItem(
            timestamp: timestamp, type: .url, contentHash: hash,
            textContent: url.absoluteString, url: url, sourceApp: sourceApp
        )
    }

    private func createPDFItem(timestamp: Date, sourceApp: String?) -> ClipboardItem? {
        guard let pdfData = getPDFData() else { return nil }
        let hash = computeHash(for: pdfData)
        return ClipboardItem(
            timestamp: timestamp, type: .pdf, contentHash: hash,
            pdfData: pdfData, sourceApp: sourceApp
        )
    }

    private func createRTFItem(timestamp: Date, sourceApp: String?) -> ClipboardItem? {
        guard let rtfData = getRTFData(), !rtfData.isEmpty else { return nil }

        // Convert RTF → plain + HTML so Web UI can render without RTF binary
        var plain: String?
        var html: String?
        if let attr = try? NSAttributedString(
            data: rtfData,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) {
            let s = attr.string
            if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                plain = s
            }
            let range = NSRange(location: 0, length: attr.length)
            if let htmlData = try? attr.data(
                from: range,
                documentAttributes: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: NSNumber(value: String.Encoding.utf8.rawValue)
                ]
            ), let htmlStr = String(data: htmlData, encoding: .utf8), !htmlStr.isEmpty {
                html = htmlStr
            }
        }
        // Notes often also puts public.utf8-plain-text on the pasteboard
        if plain == nil || plain?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            plain = pasteboard.string(forType: .string)
        }

        let hash = computeHash(for: rtfData)
        return ClipboardItem(
            timestamp: timestamp, type: .rtf, contentHash: hash,
            textContent: plain,
            rtfData: rtfData,
            htmlContent: html,
            sourceApp: sourceApp
        )
    }

    private func createHTMLItem(timestamp: Date, sourceApp: String?) -> ClipboardItem? {
        guard let html = getHTML() else { return nil }
        // Companion public.utf8-plain-text often has correct newlines/spaces (所见即所得).
        // Prefer it as textContent so copy/search stay type:text without stripping HTML markup.
        var plain = getText()
        if let p = plain, p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            plain = nil
        }
        let hash = computeHash(for: html)
        return ClipboardItem(
            timestamp: timestamp, type: .html, contentHash: hash,
            textContent: plain,
            htmlContent: html, sourceApp: sourceApp
        )
    }

    private func createTextItem(timestamp: Date, sourceApp: String?) -> ClipboardItem? {
        guard let text = getText() else { return nil }
        let hash = computeHash(for: text)
        return ClipboardItem(
            timestamp: timestamp, type: .text, contentHash: hash,
            textContent: text, sourceApp: sourceApp
        )
    }

    private func createRawItem(timestamp: Date, sourceApp: String?) -> ClipboardItem? {
        guard let rawData = getRawData() else { return nil }
        let hash = computeHash(for: rawData)
        return ClipboardItem(
            timestamp: timestamp, type: .other, contentHash: hash,
            rawData: rawData, sourceApp: sourceApp
        )
    }
    
    private func getText() -> String? {
        pasteboard.string(forType: .string)
    }
    
    private func getHTML() -> String? {
        pasteboard.string(forType: .html)
    }
    
    private func getRTFData() -> Data? {
        pasteboard.data(forType: .rtf)
    }
    
    private func getPDFData() -> Data? {
        pasteboard.data(forType: .pdf)
    }
    
    private func getURL() -> URL? {
        if let urlString = pasteboard.string(forType: .URL), let url = URL(string: urlString) {
            return url
        }
        return nil
    }
    
    private func getFileURLs() -> [URL]? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return nil
        }
        return urls.filter { $0.isFileURL }
    }
    
    private func getImage() -> NSImage? {
        pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage
    }
    
    private func getRawData() -> Data? {
        guard let types = pasteboard.types else { return nil }
        for type in types {
            if let data = pasteboard.data(forType: type) {
                return data
            }
        }
        return nil
    }
    
    private func computeHash(for data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    private func computeHash(for string: String) -> String {
        guard let data = string.data(using: .utf8) else { return "" }
        return computeHash(for: data)
    }
    
    deinit {
        stopMonitoring()
    }
}
