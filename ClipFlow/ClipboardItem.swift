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

    /// How many capture events for this content (latest-alive).
    let copyCount: Int
    /// Soft-delete timestamp; nil = alive in main library.
    let deletedAt: Date?
    /// First capture event time (history start).
    let firstSeenAt: Date?

    // MARK: User judgment (mutable projection; payload above is immutable)
    /// Latest free-text context from the user (not part of capture payload).
    let userNote: String?
    /// Workflow stage: inbox | useful | followup | archive | reject (nil = unset).
    let userStage: String?
    /// Optional 0.5…5 rating in half-star steps; nil = unset.
    let userRating: Double?
    /// Last time user context projection changed.
    let userContextUpdatedAt: Date?
    
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
         sourceApp: String? = nil,
         copyCount: Int = 1,
         deletedAt: Date? = nil,
         firstSeenAt: Date? = nil,
         userNote: String? = nil,
         userStage: String? = nil,
         userRating: Double? = nil,
         userContextUpdatedAt: Date? = nil) {
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
        self.copyCount = max(1, copyCount)
        self.deletedAt = deletedAt
        self.firstSeenAt = firstSeenAt ?? timestamp
        self.userNote = userNote
        self.userStage = userStage
        self.userRating = userRating
        self.userContextUpdatedAt = userContextUpdatedAt
    }

    /// Normalize to half-star steps in 0.5…5.0; nil if invalid.
    static func normalizeRating(_ raw: Double?) -> Double? {
        guard let raw, raw > 0 else { return nil }
        let stepped = (raw * 2).rounded() / 2
        guard stepped >= 0.5, stepped <= 5.0 else { return nil }
        return stepped
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
                // Keep a longer preview so OCR is not mistaken as truncated in list UI
                return String(ocr.prefix(500))
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
            if let text = textContent, !text.isEmpty {
                return String(text.prefix(200))
            }
            if let html = htmlContent, !html.isEmpty {
                let plain = html.replacingOccurrences(
                    of: "<[^>]+>",
                    with: "",
                    options: .regularExpression
                )
                let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return String(trimmed.prefix(200)) }
            }
            return "Rich Text"
        case .pdf:
            return "PDF"
        case .html:
            if let text = textContent, !text.isEmpty {
                return String(text.prefix(200))
            }
            if let html = htmlContent, !html.isEmpty {
                // Strip tags for list preview only (copy path uses plain companion / UI strip).
                let plain = html.replacingOccurrences(
                    of: "<[^>]+>",
                    with: " ",
                    options: .regularExpression
                )
                let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return String(trimmed.prefix(200)) }
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
