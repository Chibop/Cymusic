import SwiftUI
import UniformTypeIdentifiers

struct SourcesScreen: View {
    @EnvironmentObject private var engine: SourceEngine
    @State private var filePicker = false
    @State private var input = ""
    @State private var error: String?


    var body: some View {
        List {
            Section {
                Picker("播放音质", selection: Binding(get: { engine.quality }, set: { value in
                    do { try engine.setQuality(value) } catch { self.error = error.localizedDescription }
                })) {
                    ForEach(SourceEngine.Quality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
            Section("已安装") {
                if engine.scripts.isEmpty { Text("尚未导入音源").foregroundStyle(.secondary) }
                if !engine.scripts.isEmpty {
                    Button("测试音源") { engine.testAll() }
                }
                ForEach(engine.scripts) { item in
                    VStack(alignment: .leading) {
                        Text(item.name)
                        if let status = engine.statuses[item.id] { Text(status).font(.caption) }
                        if let author = item.metadata["author"] { Text([author, item.metadata["version"]].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                    }.swipeActions { Button("删除", role: .destructive) { run { try engine.remove(item) } } }
                }
            }
            Section {
                Button { filePicker = true } label: { Label("选择 JavaScript 文件", systemImage: "doc.badge.plus") }
                TextField("粘贴脚本或脚本链接", text: $input, axis: .vertical).lineLimit(1...5).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("导入音源") {
                    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
                    run {
                        if let url = ProviderSession.webURL(value) {
                            let (data, response) = try await URLSession.shared.data(from: url)
                            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let script = String(data: data, encoding: .utf8) else { throw SourceFailure("下载脚本失败") }
                            try await engine.importScript(script, name: url.lastPathComponent)
                        } else { try await engine.importScript(value, name: "自定义音源") }
                        input = ""
                    }
                }.disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: { Text("添加音源") } footer: { Text("导入后会运行脚本。请选择你信任的来源。") }
            if let error = error ?? engine.notice { Text(error).foregroundStyle(.secondary) }
        }.navigationTitle("音源")
        .fileImporter(isPresented: $filePicker, allowedContentTypes: [.javaScript, .plainText, .data]) { result in
            run {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                try await engine.importScript(String(contentsOf: url, encoding: .utf8), name: url.deletingPathExtension().lastPathComponent)
            }
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        error = nil
        Task { @MainActor in
            do { try await operation() } catch { self.error = error.localizedDescription }
        }
    }
}
