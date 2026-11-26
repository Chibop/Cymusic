import SwiftUI

private struct SharedSource: Decodable {
    enum Kind: String, Decodable { case text, url }
    let kind: Kind
    let value: String
    let name: String

    func confirmedText() async throws -> String {
        if kind == .text { return value }
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased()), url.host != nil else {
            throw URLError(.badURL)
        }
        let limit = 4 * 1024 * 1024
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else { throw ImportError("服务器返回 HTTP \(http.statusCode)。") }
        guard response.expectedContentLength <= limit else { throw ImportError("脚本超过 4 MB。") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw ImportError("脚本超过 4 MB。") }
            data.append(byte)
        }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0"),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError("链接未返回有效的 UTF-8 脚本文本。")
        }
        return text
    }
}

private struct ImportError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private struct InboxItem: Identifiable {
    let id: URL
    let content: Result<SharedSource, Error>
}

extension View {
    func receiveSharedSource(_ receive: @escaping @MainActor (String, String) async throws -> Void) -> some View {
        modifier(SharedSourceReceiver(receive: receive))
    }
}

private struct SharedSourceReceiver: ViewModifier {
    @Environment(\.scenePhase) private var phase
    let receive: @MainActor (String, String) async throws -> Void
    @State private var item: InboxItem?
    @State private var scanNext = false
    @State private var inboxError: String?

    func body(content: Content) -> some View {
        content.onAppear { scan() }
            .onChange(of: phase) { if $0 == .active { scan() } }
            .sheet(item: $item, onDismiss: {
                if scanNext { scanNext = false; scan() }
            }) { current in
                SharedSourceConfirmation(item: current, receive: receive) {
                    scanNext = true
                    item = nil
                }
            }
            .alert("无法读取共享目录", isPresented: Binding(get: { inboxError != nil }, set: { if !$0 { inboxError = nil } })) {
                Button("确定") { inboxError = nil }
            } message: { Text(inboxError ?? "") }
    }

    private func scan() {
        guard item == nil else { return }
        let files = FileManager.default
        do {
            guard let group = files.containerURL(forSecurityApplicationGroupIdentifier: "group.com.music.player.gyc") else {
                throw ImportError("请检查 CyMusic 的 App Group 配置。")
            }
            let inbox = group.appendingPathComponent("SharedSourceInbox", isDirectory: true)
            try files.createDirectory(at: inbox, withIntermediateDirectories: true)
            let urls = try files.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)
            let oldest = try urls.filter { $0.pathExtension == "json" }.map { url in
                (url, try url.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast)
            }.min { $0.1 < $1.1 }
            if let url = oldest?.0 {
                item = InboxItem(id: url, content: Result { try JSONDecoder().decode(SharedSource.self, from: Data(contentsOf: url)) })
            }
        } catch { inboxError = error.localizedDescription }
    }
}

private struct SharedSourceConfirmation: View {
    let item: InboxItem
    let receive: @MainActor (String, String) async throws -> Void
    let finish: () -> Void
    @State private var busy = false
    @State private var imported = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                switch item.content {
                case .success(let source):
                    Section("分享内容") {
                        Text(verbatim: source.name)
                        Text(verbatim: String(source.value.prefix(1000))).font(.footnote.monospaced()).foregroundStyle(.secondary)
                    }
                    if let errorMessage { Section("导入提示") { Text(verbatim: errorMessage) } }
                    Button {
                        guard !busy else { return }
                        busy = true
                        Task { @MainActor in
                            defer { busy = false }
                            do {
                                if !imported {
                                    let text = try await source.confirmedText()
                                    try await receive(text, source.name)
                                    imported = true
                                }
                                try removeItem()
                            } catch { errorMessage = error.localizedDescription }
                        }
                    } label: {
                        if busy { ProgressView() }
                        else { Text(imported ? "完成" : (source.kind == .url ? "下载并导入" : "导入音源")) }
                    }.disabled(busy)
                case .failure(let error):
                    Section("无法读取分享内容") { Text(errorMessage ?? error.localizedDescription) }
                }
                if !imported {
                    Button("丢弃", role: .destructive) {
                        do { try removeItem() } catch { errorMessage = error.localizedDescription }
                    }.disabled(busy)
                }
            }
            .navigationTitle("导入共享音源").navigationBarTitleDisplayMode(.inline)
        }.interactiveDismissDisabled(busy || imported)
    }

    private func removeItem() throws {
        try FileManager.default.removeItem(at: item.id)
        finish()
    }
}
