import SwiftUI
import AppKit
import PDFKit

struct ContentView: View {
    @StateObject private var viewModel = ClipboardViewModel()
    @State private var webServer: WebServer?
    @State private var isWebServerRunning = false
    @State private var selectedItem: ClipboardItem?
    // 移除不必要的 showDetail 状态，依赖 selectedItem 展示详情
    
    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let item = selectedItem {
                ItemDetailView(item: item, viewModel: viewModel)
            } else {
                emptyDetail
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .onAppear {
            viewModel.startMonitoring()
        }
        .onDisappear {
            viewModel.stopMonitoring()
            webServer?.stop()
        }
        .alert(
            "Notice",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("OK") {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .safeAreaInset(edge: .bottom) {
            Group {
                if viewModel.isICloudBackupEnabled {
                    statusBar
                } else {
                    Color.clear.frame(height: 0)
                }
            }
        }
    }
    
    private var sidebar: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            itemsList
        }
        .navigationSplitViewColumnWidth(min: 350, ideal: 400)
    }
    
    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("🐻")
                            .font(.title2)
                        Text("ClipFlow")
                    }
                    .font(.title2)
                    .fontWeight(.bold)
                    Text("Clipboard History Manager")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            
            HStack(spacing: 8) {
                monitoringToggle
                webServerToggle
                ocrToggle
                iCloudToggle
                Spacer()
                Button(action: {
                    viewModel.refresh()
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                Button(action: {
                    viewModel.clearAll()
                }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }
    
    private var monitoringToggle: some View {
        Toggle(isOn: Binding(
            get: { viewModel.isMonitoring },
            set: { isOn in
                if isOn {
                    viewModel.startMonitoring()
                } else {
                    viewModel.stopMonitoring()
                }
            }
        )) {
            HStack(spacing: 4) {
                Circle()
                    .fill(viewModel.isMonitoring ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text("Monitoring")
                    .font(.caption)
            }
        }
        .toggleStyle(.button)
    }
    
    private var webServerToggle: some View {
        Toggle(isOn: $isWebServerRunning) {
            HStack(spacing: 4) {
                Circle()
                    .fill(isWebServerRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text("Web Server")
                    .font(.caption)
            }
        }
        .toggleStyle(.button)
        .onChange(of: isWebServerRunning) { newValue in
            if newValue {
                webServer = WebServer()
                webServer?.start()
            } else {
                webServer?.stop()
                webServer = nil
            }
        }
    }
    
    private var ocrToggle: some View {
        Toggle(isOn: Binding(
            get: { viewModel.isOCREnabled },
            set: { viewModel.isOCREnabled = $0 }
        )) {
            HStack(spacing: 4) {
                Image(systemName: "text.viewfinder")
                Text("OCR")
                    .font(.caption)
            }
        }
        .toggleStyle(.button)
        .onChange(of: viewModel.isOCREnabled) { newValue in
            if newValue {
                if let item = selectedItem, item.type == .image {
                    viewModel.runOCR(on: item)
                } else {
                    // 立即给出可见反馈
                    viewModel.errorMessage = "请先选中一条图片项再执行 OCR"
                }
            }
        }
    }
    
    private var iCloudToggle: some View {
        Toggle(isOn: Binding(
            get: { viewModel.isICloudBackupEnabled },
            set: { viewModel.isICloudBackupEnabled = $0 }
        )) {
            HStack(spacing: 4) {
                Image(systemName: "icloud")
                Text("iCloud Backup")
                    .font(.caption)
            }
        }
        .toggleStyle(.button)
        .onChange(of: viewModel.isICloudBackupEnabled) { newValue in
            viewModel.onICloudBackupToggle(newValue)
        }
    }

    // 底部状态栏：展示 iCloud 同步状态/权限问题
    private var statusBar: some View {
        HStack(spacing: 12) {
            if viewModel.isICloudBackupEnabled {
                Image(systemName: "icloud").foregroundColor(.secondary)
                if viewModel.iCloudSyncInProgress {
                    ProgressView().controlSize(.small)
                    Text(viewModel.iCloudSyncPhase ?? "同步中…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if let path = viewModel.lastICloudBackupPath {
                    Image(systemName: "checkmark.circle").foregroundColor(.green)
                    Text("已备份：\(path)")
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if !viewModel.iCloudContainerAvailable {
                    Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
                    Text("未检测到 iCloud 容器，请登录并启用 iCloud Drive")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button {
                        viewModel.diagnoseICloud()
                    } label: {
                        Image(systemName: "wrench.and.screwdriver")
                    }
                    .buttonStyle(.link)
                    .help("诊断 iCloud：检查登录、容器与写权限")
                } else {
                    Text("iCloud 待机")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
    
    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search...", text: $viewModel.searchText)
                .textFieldStyle(.plain)
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
    
    private var itemsList: some View {
        Group {
            if viewModel.isLoading {
                loadingView
            } else if viewModel.items.isEmpty {
                emptyView
            } else {
                listView
            }
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No clipboard items yet")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Copy something to get started!")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var listView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(viewModel.items) { item in
                    Button {
                        selectedItem = item
                    } label: {
                        ItemRowView(item: item, isSelected: selectedItem?.id == item.id)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { contextMenu(for: item) }
                }
            }
            .padding()
        }
    }
    
    @ViewBuilder
    private func contextMenu(for item: ClipboardItem) -> some View {
        Button(action: {
            viewModel.copyItem(item)
        }) {
            Label("Copy", systemImage: "doc.on.doc")
        }

        Button(action: {
            selectedItem = item
        }) {
            Label("View Details", systemImage: "eye")
        }
        
        Divider()
        
        Button(role: .destructive, action: {
            viewModel.deleteItem(item)
            if selectedItem?.id == item.id {
                selectedItem = nil
            }
        }) {
            Label("Delete", systemImage: "trash")
        }
    }
    
    private var emptyDetail: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.left")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("Select an item to view details")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ItemRowView: View {
    let item: ClipboardItem
    let isSelected: Bool
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale.current
        return f
    }()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TypeBadge(type: item.type)
                Spacer()
                Text(Self.timeFormatter.string(from: item.timestamp))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Text(item.preview())
                .font(.body)
                .lineLimit(3)
                .foregroundColor(.primary)
            
            if let sourceApp = item.sourceApp {
                Text("From: \(sourceApp)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color(nsColor: .textBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }
}

struct TypeBadge: View {
    let type: ClipboardType
    
    var body: some View {
        Text(type.rawValue.capitalized)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(badgeColor.opacity(0.2))
            .foregroundColor(badgeColor)
            .cornerRadius(4)
    }
    
    private var badgeColor: Color {
        switch type {
        case .text: return .blue
        case .image: return .pink
        case .file: return .green
        case .url: return .orange
        case .rtf: return .purple
        case .pdf: return .red
        case .html: return .teal
        case .other: return .gray
        }
    }
}

struct ItemDetailView: View {
    let item: ClipboardItem
    let viewModel: ClipboardViewModel
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                content
            }
            .padding()
        }
        .navigationTitle("Clipboard Item")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: {
                    viewModel.copyItem(item)
                }) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                
                Button(role: .destructive, action: {
                    viewModel.deleteItem(item)
                }) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
    
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TypeBadge(type: item.type)
                Spacer()
                Text(item.timestamp, style: .date)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            if let sourceApp = item.sourceApp {
                HStack {
                    Image(systemName: "app.fill")
                    Text(sourceApp)
                        .font(.subheadline)
                }
                .foregroundColor(.secondary)
            }
            
            Text(item.timestamp, style: .time)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    @ViewBuilder
    private var content: some View {
        switch item.type {
        case .text:
            if let text = item.textContent {
                TextContent(text: text)
            }
        case .image:
            if let imageData = item.imageData, let image = NSImage(data: imageData) {
                ImageContent(image: image, ocrText: item.ocrText)
            }
        case .file:
            if let urls = item.fileURLs {
                FileContent(urls: urls)
            }
        case .url:
            if let url = item.url {
                URLContent(url: url)
            }
        case .rtf:
            if let rtfData = item.rtfData {
                RTFContent(data: rtfData)
            }
        case .pdf:
            PDFContent(data: item.pdfData)
        case .html:
            if let html = item.htmlContent {
                HTMLContent(html: html)
            }
        case .other:
            OtherContent()
        }
    }
}

struct TextContent: View {
    let text: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Content")
                .font(.headline)
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
        }
    }
}

struct ImageContent: View {
    let image: NSImage
    let ocrText: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Image")
                .font(.headline)
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 400)
                .cornerRadius(8)
            if let ocrText = ocrText, !ocrText.isEmpty {
                Divider()
                Text("Recognized Text")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text(ocrText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)
            }
        }
    }
}

struct FileContent: View {
    let urls: [URL]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Files")
                .font(.headline)
            ForEach(urls, id: \.self) { url in
                HStack {
                    Image(systemName: "doc.fill")
                    Text(url.lastPathComponent)
                    Spacer()
                    Text(url.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
            }
        }
    }
}

struct URLContent: View {
    let url: URL
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("URL")
                .font(.headline)
            Link(destination: url) {
                Text(url.absoluteString)
                    .font(.body)
                    .foregroundColor(.blue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)
            }
        }
    }
}

struct RTFContent: View {
    let data: Data
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rich Text").font(.headline)
            RTFTextView(rtfData: data)
                .frame(maxWidth: .infinity, minHeight: 120)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
        }
    }
}

struct RTFTextView: NSViewRepresentable {
    let rtfData: Data
    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isRichText = true
        textView.backgroundColor = .clear
        if let attr = try? NSAttributedString(data: rtfData, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            textView.textStorage?.setAttributedString(attr)
        } else {
            // 无法解析时进行转义展示
            let escaped = String(decoding: rtfData, as: UTF8.self)
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            textView.string = escaped
        }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        return scroll
    }
    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

struct PDFContent: View {
    var data: Data? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PDF").font(.headline)
            if let data, let doc = PDFDocument(data: data) {
                PDFKitView(document: doc)
                    .frame(maxHeight: 400)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)
            } else {
                // 无法展示时转义为文本说明
                Text("无法预览该 PDF，文件已保存于本地数据库").font(.caption).foregroundColor(.secondary)
            }
        }
    }
}

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.autoScales = true
        view.document = document
        return view
    }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}

struct HTMLContent: View {
    let html: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HTML")
                .font(.headline)
            Text(html)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
        }
    }
}

struct OtherContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Other Content")
                .font(.headline)
            // 无法展示类型使用转义文本说明
            Text("Unsupported content type — 使用原始数据安全转义展示")
                .font(.body)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
        }
    }
}

#Preview {
    ContentView()
}
