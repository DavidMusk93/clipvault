import Foundation
import AppKit

enum ClipboardType: String, Codable {
    case text
    case image
    case file
    case url
    case rtf
    case pdf
    case html
    case other
}

struct ClipboardItem: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let timestamp: Date
    let type: ClipboardType
    let contentHash: String
    
    let textContent: String?
    let imageData: Data?
    let fileURLs: [URL]?
    let url: URL?
    let rtfData: Data?
    let pdfData: Data?
    let htmlContent: String?
    let rawData: Data?
    
    // OCR 识别出的文本
    let ocrText: String?
    
    let sourceApp: String?
    
    init(id: UUID = UUID(),
         timestamp: Date = Date(),
         type: ClipboardType,
         contentHash: String,
         textContent: String? = nil,
         imageData: Data? = nil,
         fileURLs: [URL]? = nil,
         url: URL? = nil,
         rtfData: Data? = nil,
         pdfData: Data? = nil,
         htmlContent: String? = nil,
         rawData: Data? = nil,
         ocrText: String? = nil,
         sourceApp: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.contentHash = contentHash
        self.textContent = textContent
        self.imageData = imageData
        self.fileURLs = fileURLs
        self.url = url
        self.rtfData = rtfData
        self.pdfData = pdfData
        self.htmlContent = htmlContent
        self.rawData = rawData
        self.ocrText = ocrText
        self.sourceApp = sourceApp
    }
    
    // swiftlint:disable cyclomatic_complexity
    func preview() -> String {
        switch type {
        case .text:
            if let text = textContent {
                return String(text.prefix(100))
            }
        case .image:
            if let ocr = ocrText, !ocr.isEmpty {
                return String(ocr.prefix(100))
            }
            return "Image"
        case .file:
            if let urls = fileURLs {
                return urls.map { $0.lastPathComponent }.joined(separator: ", ")
            }
        case .url:
            if let url = url {
                return url.absoluteString
            }
        case .rtf:
            return "Rich Text"
        case .pdf:
            return "PDF"
        case .html:
            if let html = htmlContent {
                return String(html.prefix(100))
            }
        case .other:
            return "Other"
        }
        return "No preview"
    }
    // swiftlint:enable cyclomatic_complexity
    
    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        lhs.contentHash == rhs.contentHash
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(contentHash)
    }
}
