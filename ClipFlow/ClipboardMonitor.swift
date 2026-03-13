import Foundation
import AppKit
import CommonCrypto

class ClipboardMonitor: ObservableObject {
    @Published var lastItem: ClipboardItem?
    @Published var isMonitoring = false
    
    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private let pasteboard = NSPasteboard.general
    
    private let monitorQueue = DispatchQueue(label: "com.clipflow.monitor", qos: .userInitiated)
    
    init() {
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
        
        guard currentChangeCount != lastChangeCount else { return }
        
        lastChangeCount = currentChangeCount
        
        monitorQueue.async { [weak self] in
            guard let self = self, let item = self.createClipboardItem() else { return }
            
            DispatchQueue.main.async {
                self.lastItem = item
            }
        }
    }
    
    private func createClipboardItem() -> ClipboardItem? {
        let timestamp = Date()
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        
        let types = pasteboard.types ?? []
        
        if let fileURLs = getFileURLs(), !fileURLs.isEmpty {
            let hash = computeHash(for: fileURLs.map { $0.path }.joined())
            return ClipboardItem(
                timestamp: timestamp,
                type: .file,
                contentHash: hash,
                fileURLs: fileURLs,
                sourceApp: sourceApp
            )
        }
        
        if let image = getImage(), let imageData = image.tiffRepresentation {
            let hash = computeHash(for: imageData)
            return ClipboardItem(
                timestamp: timestamp,
                type: .image,
                contentHash: hash,
                imageData: imageData,
                sourceApp: sourceApp
            )
        }
        
        if let url = getURL() {
            let hash = computeHash(for: url.absoluteString)
            return ClipboardItem(
                timestamp: timestamp,
                type: .url,
                contentHash: hash,
                textContent: url.absoluteString,
                url: url,
                sourceApp: sourceApp
            )
        }
        
        if let pdfData = getPDFData() {
            let hash = computeHash(for: pdfData)
            return ClipboardItem(
                timestamp: timestamp,
                type: .pdf,
                contentHash: hash,
                pdfData: pdfData,
                sourceApp: sourceApp
            )
        }
        
        if let rtfData = getRTFData() {
            let hash = computeHash(for: rtfData)
            return ClipboardItem(
                timestamp: timestamp,
                type: .rtf,
                contentHash: hash,
                rtfData: rtfData,
                sourceApp: sourceApp
            )
        }
        
        if let html = getHTML() {
            let hash = computeHash(for: html)
            return ClipboardItem(
                timestamp: timestamp,
                type: .html,
                contentHash: hash,
                htmlContent: html,
                sourceApp: sourceApp
            )
        }
        
        if let text = getText() {
            let hash = computeHash(for: text)
            return ClipboardItem(
                timestamp: timestamp,
                type: .text,
                contentHash: hash,
                textContent: text,
                sourceApp: sourceApp
            )
        }
        
        if let rawData = getRawData() {
            let hash = computeHash(for: rawData)
            return ClipboardItem(
                timestamp: timestamp,
                type: .other,
                contentHash: hash,
                rawData: rawData,
                sourceApp: sourceApp
            )
        }
        
        return nil
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
