import Foundation
import ImageIO
import CoreGraphics

/// Capture-time image codec. CAS blobs live on disk, but pixels still need a bound.
///
/// Incident 2026-08-31 11:02:38 (`5D8CC9C3-37FD-41E1-B488-C3F77251EC67`):
/// a ~14:1 scrolling screenshot was scaled by **long** edge 1600 → stored
/// 113×1600 JPEG; OCR collapsed to gibberish. Strips must scale by the
/// **short** edge so body text stays readable.
enum ImageStoragePolicy {
    /// Photos / ordinary screenshots: long-edge cap.
    static let maxLongEdge: CGFloat = 2048
    /// Scrolling shots / panoramas: keep the short edge OCR-able.
    static let maxShortEdge: CGFloat = 1600
    /// Treat as a strip at or above this aspect (long/short).
    static let stripAspect: CGFloat = 2.2
    static let maxPixels: CGFloat = 24_000_000
    static let maxLongEdgeStrip: CGFloat = 24_000
    static let maxKeepOriginalBytes = 12_000_000

    #if DEBUG
    private static let _checked: Void = {
        // Incident dimensions (inferred from 113×1600 @ long-edge 1600).
        precondition(abs(scale(width: 1179, height: 16_690) - 1) < 0.001)
        precondition(scale(width: 113, height: 1600) >= 0.999)
        let photo = scale(width: 3024, height: 1964)
        precondition(abs(photo - 2048 / 3024) < 0.002)
        precondition(scale(width: 800, height: 600) >= 0.999)
    }()
    #endif

    static func isStrip(width: CGFloat, height: CGFloat) -> Bool {
        let short = max(1, min(width, height))
        return max(width, height) / short >= stripAspect
    }

    static func scale(width: CGFloat, height: CGFloat) -> CGFloat {
        let w = max(1, width)
        let h = max(1, height)
        let short = min(w, h)
        let long = max(w, h)
        var s: CGFloat = 1
        if isStrip(width: w, height: h) {
            s = min(s, maxShortEdge / short, maxLongEdgeStrip / long)
        } else {
            s = min(s, maxLongEdge / long)
        }
        let pixels = w * h
        if pixels * s * s > maxPixels {
            s = min(s, (maxPixels / pixels).squareRoot())
        }
        return min(1, s)
    }

    static func compressForStorage(_ data: Data) -> Data? {
        #if DEBUG
        _ = _checked
        #endif
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
        let cgImage = CGImageSourceCreateImageAtIndex(
            source, 0,
            [kCGImageSourceShouldCache: true] as CFDictionary
        ) else {
            return nil
        }

        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let s = scale(width: w, height: h)
        let strip = isStrip(width: w, height: h)
        let tw = max(1, Int((w * s).rounded()))
        let th = max(1, Int((h * s).rounded()))

        if s >= 0.999,
           data.count <= maxKeepOriginalBytes,
           isPNG(data) || isJPEG(data) {
            if strip {
                print("[capture] strip \(Int(w))x\(Int(h)) keep original \(data.count)B")
            }
            return data
        }

        let raster: CGImage
        if s >= 0.999 {
            raster = cgImage
        } else if let scaled = resample(cgImage, width: tw, height: th) {
            raster = scaled
        } else {
            return nil
        }

        let useJPEG = shouldJPEG(
            sourceBytes: data.count,
            outWidth: tw,
            outHeight: th,
            isStrip: strip
        )
        guard let encoded = encode(raster, jpeg: useJPEG, quality: strip ? 0.90 : 0.82) else {
            return nil
        }
        print("[capture] image \(Int(w))x\(Int(h)) → \(tw)x\(th) jpeg=\(useJPEG) strip=\(strip) \(encoded.count)B")
        return encoded
    }

    static func largestPayload(_ candidates: [Data]) -> Data? {
        var best: (Data, Int, Int)?
        for data in candidates where !data.isEmpty {
            let area: Int
            if let size = pixelSize(of: data) {
                area = size.0 * size.1
            } else {
                area = 0
            }
            // Pixel area dominates; bytes break ties (richer encoding of the same frame).
            if let cur = best {
                if area > cur.1 || (area == cur.1 && data.count > cur.2) {
                    best = (data, area, data.count)
                }
            } else {
                best = (data, area, data.count)
            }
        }
        return best?.0
    }

    static func pixelSize(of data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        guard let w, let h, w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// Feed card preview. Tall strips: crop the **top** 4:3 at source, then
    /// scale by width (no long-edge 360 — that made 1179×16690 into a 25px sliver).
    static func encodePreview(_ data: Data, maxShort: CGFloat, cropTallToCard: Bool) -> (Data, String)? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
        let image = CGImageSourceCreateImageAtIndex(
            source, 0,
            [kCGImageSourceShouldCache: true] as CFDictionary
        ) else {
            return nil
        }
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        guard w > 0, h > 0 else { return nil }

        var work = image
        if cropTallToCard, h / w >= stripAspect {
            let cropH = Int(min(h, max(1, w * 0.75)).rounded())
            if let cropped = crop(image, pixelRect: CGRect(x: 0, y: 0, width: w, height: CGFloat(cropH))) {
                work = cropped
            }
        }

        let cw = CGFloat(work.width)
        let ch = CGFloat(work.height)
        let short = min(cw, ch)
        let s = min(1, maxShort / max(short, 1))
        let tw = max(1, Int((cw * s).rounded()))
        let th = max(1, Int((ch * s).rounded()))
        let raster = (s < 0.999 ? (resample(work, width: tw, height: th) ?? work) : work)
        let quality: CGFloat = cropTallToCard ? 0.86 : 0.88
        guard let encoded = encode(raster, jpeg: true, quality: quality) else { return nil }
        return (encoded, "image/jpeg")
    }

    static func isPNG(_ data: Data) -> Bool {
        data.count >= 8 && data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47
    }

    static func isJPEG(_ data: Data) -> Bool {
        data.count >= 2 && data[0] == 0xFF && data[1] == 0xD8
    }

    private static func shouldJPEG(sourceBytes: Int, outWidth: Int, outHeight: Int, isStrip: Bool) -> Bool {
        let pixels = outWidth * outHeight
        if isStrip {
            // JPEG ringing destroys CJK on UI strips; PNG unless the raster is huge.
            return pixels > 8_000_000
        }
        return sourceBytes > 400_000 || pixels > 900_000
    }

    /// Crop in top-left image space (y=0 is the visual top of the bitmap).
    static func crop(_ image: CGImage, pixelRect: CGRect) -> CGImage? {
        let r = pixelRect.integral
        let dw = max(1, Int(r.width))
        let dh = max(1, Int(r.height))
        guard dw > 0, dh > 0 else { return nil }
        if r.minX <= 0.5, r.minY <= 0.5, dw >= image.width, dh >= image.height {
            return image
        }
        guard let ctx = CGContext(
            data: nil, width: dw, height: dh,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        ctx.draw(
            image,
            in: CGRect(
                x: -r.minX,
                y: CGFloat(dh) - imgH + r.minY,
                width: imgW,
                height: imgH
            )
        )
        return ctx.makeImage()
    }

    private static func resample(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        // Always RGB: gray/CMYK sources fail or surprise-encode if we reuse their space.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private static func encode(_ image: CGImage, jpeg: Bool, quality: CGFloat) -> Data? {
        let out = NSMutableData()
        let uti = (jpeg ? "public.jpeg" : "public.png") as CFString
        guard let dest = CGImageDestinationCreateWithData(out, uti, 1, nil) else {
            return nil
        }
        let props: [CFString: Any] = jpeg
            ? [kCGImageDestinationLossyCompressionQuality: quality]
            : [:]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
