import SwiftUI

@main
struct ClipFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover = NSPopover()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBarItem()
        setupPopover()
        // 使用 emoji 作为 Dock 应用图标
        NSApp.applicationIconImage = LogoRenderer.makeEmojiIcon("🐻")
        // 首次落盘日志，便于用户定位文件
        LogManager.shared.write("App launched")
    }
    
    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            // 使用 emoji 作为状态栏图标
            button.image = nil
            button.title = "🐻"
            button.toolTip = "ClipFlow"
            button.action = #selector(togglePopover(_:))
        }
    }
    
    private func setupPopover() {
        popover.contentSize = NSSize(width: 400, height: 500)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ContentView())
    }
    
    @objc private func togglePopover(_ sender: AnyObject?) {
        if let button = statusItem?.button {
            if popover.isShown {
                popover.performClose(sender)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }
}

// 自绘 Logo（龙虾夹纸），用于状态栏图标
enum LogoRenderer {
    // Dock/App 图标：主体是龙虾夹纸（参考 emoji 造型，突出“钳子夹纸”）
    static func makeLobsterAppIcon(size: CGFloat = 256, scale: CGFloat = 2) -> NSImage {
        let pixel = size * scale
        let image = NSImage(size: NSSize(width: pixel, height: pixel))
        image.lockFocus()
        defer { image.unlockFocus() }
        
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            defer { ctx.restoreGState() }
            ctx.clear(CGRect(x: 0, y: 0, width: pixel, height: pixel))
            ctx.scaleBy(x: scale, y: scale)
        }
        
        // 牛头：上部头骨 + 下部口鼻（棕色）
        let headColor = NSColor.systemBrown
        headColor.setFill()
        NSBezierPath(ovalIn: CGRect(
            x: size * 0.35, y: size * 0.50, width: size * 0.30, height: size * 0.22
        )).fill()
        NSBezierPath(roundedRect: CGRect(
            x: size * 0.38, y: size * 0.38, width: size * 0.24, height: size * 0.16
        ), xRadius: size * 0.05, yRadius: size * 0.05).fill()
        
        // 耳朵
        NSBezierPath(ovalIn: CGRect(x: size * 0.28, y: size * 0.54, width: size * 0.12, height: size * 0.10)).fill()
        NSBezierPath(ovalIn: CGRect(x: size * 0.60, y: size * 0.54, width: size * 0.12, height: size * 0.10)).fill()
        
        // 角（浅色）
        let hornColor = NSColor(calibratedWhite: 0.95, alpha: 1)
        hornColor.setFill()
        let lh = NSBezierPath()
        lh.move(to: CGPoint(x: size * 0.36, y: size * 0.64))
        lh.curve(
            to: CGPoint(x: size * 0.22, y: size * 0.74),
            controlPoint1: CGPoint(x: size * 0.30, y: size * 0.70),
            controlPoint2: CGPoint(x: size * 0.26, y: size * 0.74)
        )
        lh.line(to: CGPoint(x: size * 0.28, y: size * 0.66))
        lh.close()
        lh.fill()
        
        let rh = NSBezierPath()
        rh.move(to: CGPoint(x: size * 0.64, y: size * 0.64))
        rh.curve(
            to: CGPoint(x: size * 0.78, y: size * 0.74),
            controlPoint1: CGPoint(x: size * 0.70, y: size * 0.70),
            controlPoint2: CGPoint(x: size * 0.74, y: size * 0.74)
        )
        rh.line(to: CGPoint(x: size * 0.72, y: size * 0.66))
        rh.close()
        rh.fill()
        
        // 眼睛与鼻孔（黑色）
        NSColor.black.setFill()
        NSBezierPath(ovalIn: CGRect(x: size * 0.46, y: size * 0.56, width: size * 0.024, height: size * 0.024)).fill()
        NSBezierPath(ovalIn: CGRect(x: size * 0.54, y: size * 0.56, width: size * 0.024, height: size * 0.024)).fill()
        NSBezierPath(ovalIn: CGRect(x: size * 0.49, y: size * 0.44, width: size * 0.02, height: size * 0.028)).fill()
        NSBezierPath(ovalIn: CGRect(x: size * 0.53, y: size * 0.44, width: size * 0.02, height: size * 0.028)).fill()
        
        return image
    }

    // 状态栏剪影版：单色剪影，钳子夹纸，适配 18/22pt 模板着色
    static func makeLobsterStatusGlyph(size: CGFloat = 18, scale: CGFloat = 2) -> NSImage {
        let pixel = size * scale
        let image = NSImage(size: NSSize(width: pixel, height: pixel))
        image.lockFocus()
        defer { image.unlockFocus() }
        
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            defer { ctx.restoreGState() }
            ctx.clear(CGRect(x: 0, y: 0, width: pixel, height: pixel))
            ctx.scaleBy(x: scale, y: scale)
        }
        
        NSColor.black.setFill()
        
        // 头部
        NSBezierPath(ovalIn: CGRect(x: size * 0.36, y: size * 0.58, width: size * 0.28, height: size * 0.18)).fill()
        NSBezierPath(roundedRect: CGRect(x: size * 0.40, y: size * 0.46, width: size * 0.20, height: size * 0.12), xRadius: 2, yRadius: 2).fill()
        
        // 耳朵
        NSBezierPath(ovalIn: CGRect(x: size * 0.30, y: size * 0.60, width: size * 0.10, height: size * 0.08)).fill()
        NSBezierPath(ovalIn: CGRect(x: size * 0.60, y: size * 0.60, width: size * 0.10, height: size * 0.08)).fill()
        
        // 角（三角弧）
        let lh = NSBezierPath()
        lh.move(to: CGPoint(x: size * 0.38, y: size * 0.66))
        lh.curve(to: CGPoint(x: size * 0.26, y: size * 0.74), controlPoint1: CGPoint(x: size * 0.32, y: size * 0.70), controlPoint2: CGPoint(x: size * 0.28, y: size * 0.74))
        lh.line(to: CGPoint(x: size * 0.32, y: size * 0.66))
        lh.close()
        lh.fill()
        
        let rh = NSBezierPath()
        rh.move(to: CGPoint(x: size * 0.62, y: size * 0.66))
        rh.curve(to: CGPoint(x: size * 0.74, y: size * 0.74), controlPoint1: CGPoint(x: size * 0.68, y: size * 0.70), controlPoint2: CGPoint(x: size * 0.72, y: size * 0.74))
        rh.line(to: CGPoint(x: size * 0.68, y: size * 0.66))
        rh.close()
        rh.fill()
        
        return image
    }

    // 使用 emoji 生成 NSImage 以作为 Dock 图标
    static func makeEmojiIcon(_ emoji: String, size: CGFloat = 256, scale: CGFloat = 2) -> NSImage {
        let pixel = size * scale
        let image = NSImage(size: NSSize(width: pixel, height: pixel))
        image.lockFocus(); defer { image.unlockFocus() }
        let rect = CGRect(x: 0, y: 0, width: pixel, height: pixel)
        NSColor.clear.setFill(); rect.fill()
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * 0.8),
            .paragraphStyle: style
        ]
        let str = NSString(string: emoji)
        let drawRect = CGRect(x: 0, y: (pixel - size) / 2, width: pixel, height: size)
        str.draw(in: drawRect, withAttributes: attrs)
        return image
    }
}
