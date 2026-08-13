import Foundation
import AppKit
import CommonCrypto
import Vision
import ImageIO
import CoreGraphics

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
            let imageData = compressForStorage(rawData) ?? normalizeToPNG(rawData) ?? rawData
            let ocrText = performOCR(on: imageData)
            let hash = computeHash(for: imageData)
            return ClipboardItem(
                timestamp: timestamp, type: .image, contentHash: hash,
                imageData: imageData, fileURLs: fileURLs,
                ocrText: ocrText, sourceApp: sourceApp
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
        // Downscale + PNG for storage; blobs live on disk (not SQLite) — keep payloads lean.
        let imageData = compressForStorage(rawData) ?? normalizeToPNG(rawData) ?? rawData
        let ocrText = performOCR(on: imageData)
        let hash = computeHash(for: imageData)
        return ClipboardItem(
            timestamp: timestamp, type: .image, contentHash: hash,
            imageData: imageData, ocrText: ocrText, sourceApp: sourceApp
        )
    }

    /// Max long edge 1600px; prefer JPEG for large photos, PNG for small/UI shots.
    private func compressForStorage(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return normalizeToPNG(data)
        }
        let maxEdge: CGFloat = 1600
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let scale = min(1.0, maxEdge / max(w, h))
        let tw = max(1, Int(w * scale))
        let th = max(1, Int(h * scale))

        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: tw, height: th,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return normalizeToPNG(data) }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let scaled = ctx.makeImage() else { return normalizeToPNG(data) }

        let out = NSMutableData()
        // Screenshots/UI stay sharp as PNG; large photographic frames → JPEG ~0.8
        let useJPEG = (data.count > 400_000) || (tw * th > 900_000)
        let uti = useJPEG ? "public.jpeg" as CFString : "public.png" as CFString
        guard let dest = CGImageDestinationCreateWithData(out, uti, 1, nil) else {
            return normalizeToPNG(data)
        }
        let props: [CFString: Any] = useJPEG
            ? [kCGImageDestinationLossyCompressionQuality: 0.82]
            : [:]
        CGImageDestinationAddImage(dest, scaled, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return normalizeToPNG(data) }
        return out as Data
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
        if let pngData = pasteboard.data(forType: .png), !pngData.isEmpty { return pngData }
        if let tiffData = pasteboard.data(forType: .tiff), !tiffData.isEmpty { return tiffData }
        let jpegType = NSPasteboard.PasteboardType("public.jpeg")
        if let jpegData = pasteboard.data(forType: jpegType), !jpegData.isEmpty { return jpegData }
        if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
           let tiff = image.tiffRepresentation {
            return tiff
        }
        if let urls = getFileURLs(), let first = urls.first {
            let ext = first.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "webp", "gif", "heic", "tiff"].contains(ext),
               let fileData = try? Data(contentsOf: first) {
                return fileData
            }
        }
        return nil
    }

    /// Decode clipboard bytes to CGImage with ImageIO first (preserves resolution).
    private func makeCGImage(from imageData: Data) -> CGImage? {
        if let source = CGImageSourceCreateWithData(imageData as CFData, nil),
           CGImageSourceGetCount(source) > 0,
           let image = CGImageSourceCreateImageAtIndex(
                source, 0,
                [kCGImageSourceShouldCache: true] as CFDictionary
           ) {
            return image
        }
        // Fallback: NSImage → TIFF → bitmap
        guard let nsImage = NSImage(data: imageData),
              let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.cgImage
    }

    private func performOCR(on imageData: Data) -> String? {
        guard let cgImage = makeCGImage(from: imageData) else {
            return nil
        }

        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Language correction can over-edit UI/code screenshots; keep off for completeness.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        // Keep tiny glyphs (status bar, chips, badges)
        request.minimumTextHeight = 0.008
        if #available(macOS 13.0, *) {
            request.automaticallyDetectsLanguage = true
        }

        do {
            try requestHandler.perform([request])
            guard let results = request.results, !results.isEmpty else { return nil }
            return reconstructOCRText(from: results)
        } catch {
            print("[OCR] perform failed: \(error)")
            return nil
        }
    }

    /// Rebuild multi-line / multi-column text from Vision boxes.
    /// Vision bbox origin is bottom-left; higher midY = higher on screen.
    private func reconstructOCRText(from observations: [VNRecognizedTextObservation]) -> String? {
        struct TextBox {
            let text: String
            let minX: CGFloat
            let maxX: CGFloat
            let midY: CGFloat
            let height: CGFloat
        }

        let boxes: [TextBox] = observations.compactMap { obs in
            // Prefer top candidate; fall back to next if empty after trim
            let candidates = obs.topCandidates(3)
            let raw = candidates.lazy
                .map { $0.string.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            guard let text = raw else { return nil }
            let b = obs.boundingBox
            return TextBox(
                text: text,
                minX: b.minX,
                maxX: b.maxX,
                midY: b.midY,
                height: max(b.height, 0.001)
            )
        }
        guard !boxes.isEmpty else { return nil }

        let avgHeight = boxes.map(\.height).reduce(0, +) / CGFloat(boxes.count)
        // Boxes whose vertical centers are within this threshold belong to the same line
        let lineThreshold = max(avgHeight * 0.6, 0.012)

        // Global order: top→bottom, then left→right within similar Y
        let sorted = boxes.sorted { a, b in
            if abs(a.midY - b.midY) < lineThreshold {
                return a.minX < b.minX
            }
            return a.midY > b.midY
        }

        // Cluster into reading lines
        var lines: [[TextBox]] = []
        for box in sorted {
            if let lastIndex = lines.indices.last {
                let lineMid = lines[lastIndex].map(\.midY).reduce(0, +) / CGFloat(lines[lastIndex].count)
                if abs(lineMid - box.midY) < lineThreshold {
                    lines[lastIndex].append(box)
                    continue
                }
            }
            lines.append([box])
        }

        let lineStrings: [String] = lines.map { line in
            let ordered = line.sorted { $0.minX < $1.minX }
            var result = ""
            for (i, box) in ordered.enumerated() {
                if i == 0 {
                    result = box.text
                    continue
                }
                let prev = ordered[i - 1]
                let gap = box.minX - prev.maxX
                // Large horizontal gap → column / word separation
                if gap > 0.015 {
                    result += " " + box.text
                } else if shouldInsertSpace(between: prev.text, and: box.text) {
                    result += " " + box.text
                } else {
                    result += box.text
                }
            }
            return result
        }

        let text = lineStrings.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Insert space between Latin/digit tokens; keep CJK glued.
    private func shouldInsertSpace(between left: String, and right: String) -> Bool {
        guard let l = left.last, let r = right.first else { return true }
        let lCJK = isCJK(l)
        let rCJK = isCJK(r)
        if lCJK && rCJK { return false }
        if l.isWhitespace || r.isWhitespace { return false }
        // Latin/digit boundaries usually want a space
        if l.isLetter || l.isNumber || r.isLetter || r.isNumber {
            return true
        }
        return false
    }

    private func isCJK(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        switch v {
        case 0x4E00...0x9FFF,   // CJK Unified
             0x3400...0x4DBF,   // CJK Ext A
             0xF900...0xFAFF,   // CJK Compatibility
             0x3000...0x303F,   // CJK punctuation
             0xFF00...0xFFEF:   // Fullwidth forms
            return true
        default:
            return false
        }
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
