import Foundation

/// The bytes and pasteboard flavor must travel together for unknown formats.
struct RawClipboardPayload: Codable, Equatable {
    let type: String
    let data: Data
}

enum ClipboardCapturePolicy {
    static func firstNonempty<T>(_ types: [T], read: (T) -> Data?) -> (T, Data)? {
        for type in types {
            if let data = read(type), !data.isEmpty { return (type, data) }
        }
        return nil
    }

    static func stable<T>(expected: Int, current: () -> Int, read: () -> T?) -> T? {
        guard current() == expected, let value = read(), current() == expected else { return nil }
        return value
    }
}
