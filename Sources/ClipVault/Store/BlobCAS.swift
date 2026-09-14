import Foundation

/// Content-addressed blob filenames under `blobs/` and `live/attach/`.
///
/// Bare SHA-256 is 64 hex. RTF/PDF are stored as `{sha}.rtf.bin` / `{sha}.pdf.bin`
/// because `writeBlobFile(hash: contentHash + ".rtf")` appends `.bin`.
/// Pull must accept those typed keys; a `count == 64` reject stalls the seq
/// cursor and every later compose trx never applies.
enum BlobCAS {
    static let typedSuffixes = [".rtf", ".pdf"]

    /// Stem written to disk (no `.bin`). Nil if the key is not a CAS object.
    static func storageKey(_ hash: String) -> String? {
        let h = hash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isSHA256(h) { return h }
        for suffix in typedSuffixes where h.hasSuffix(suffix) {
            let stem = String(h.dropLast(suffix.count))
            if isSHA256(stem) { return h }
        }
        return nil
    }

    static func isSHA256(_ s: String) -> Bool {
        s.count == 64 && s.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }
}
