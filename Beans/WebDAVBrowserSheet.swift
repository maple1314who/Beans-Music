import SwiftUI

/// WebDAV 目录浏览器：浏览服务器目录，点选备份位置。
struct WebDAVBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (String) -> Void

    @State private var currentPath: String
    @State private var items: [WebDAVItem] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var showNewDirPrompt = false
    @State private var newDirName = ""

    init(initialPath: String, onSelect: @escaping (String) -> Void) {
        self.onSelect = onSelect
        _currentPath = State(initialValue: initialPath)
    }

    var body: some View {
        BeansNavigationStack {
            VStack(spacing: 0) {
                pathBar
                Divider().opacity(0.35)

                if loading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else if let errorMessage {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.beansAmber)
                        Text(errorMessage)
                            .font(BeansFont.appFont(13))
                            .foregroundStyle(Color.beansComment)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                    Spacer()
                } else if items.isEmpty {
                    Spacer()
                    Text("该目录下没有子目录")
                        .font(BeansFont.appFont(13))
                        .foregroundStyle(Color.beansComment)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(items) { item in
                                Button {
                                    enter(item)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "folder.fill")
                                            .font(.system(size: 17))
                                            .foregroundStyle(Color.beansAmber)
                                            .frame(width: 26)
                                        Text(item.name)
                                            .font(BeansFont.appFont(14))
                                            .foregroundStyle(Color.beansLabel)
                                            .lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Color.beansComment)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .background {
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(Color.primary.opacity(0.04))
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(14)
                    }
                }
            }
            .navigationTitle("选择备份位置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("选择此位置") {
                        onSelect(currentPath)
                        dismiss()
                    }
                }
            }
            .task { await load() }
            .alert("新建目录", isPresented: $showNewDirPrompt) {
                TextField("目录名", text: $newDirName)
                Button("创建") { createDirectory() }
                Button("取消", role: .cancel) { newDirName = "" }
            } message: {
                Text("将在当前目录下创建一个新目录")
            }
        }
    }

    private var pathBar: some View {
        HStack(spacing: 8) {
            Button {
                goUp()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.beansLabel)
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            Text(currentPath)
                .font(BeansFont.appFont(11))
                .foregroundStyle(Color.beansComment)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                showNewDirPrompt = true
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.beansAmber)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func load() async {
        loading = true
        errorMessage = nil
        do {
            items = try await WebDAVBackupStore.shared.listDirectories(at: currentPath)
        } catch {
            errorMessage = error.localizedDescription
            items = []
        }
        loading = false
    }

    private func enter(_ item: WebDAVItem) {
        currentPath = item.fullPath
        Task { await load() }
    }

    private func goUp() {
        guard var components = URLComponents(string: currentPath) else { return }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        guard let idx = path.lastIndex(of: "/") else { return }
        path = String(path[..<idx]) + "/"
        components.path = path
        guard let newPath = components.string else { return }
        currentPath = newPath
        Task { await load() }
    }

    private func createDirectory() {
        let name = newDirName.trimmingCharacters(in: .whitespacesAndNewlines)
        newDirName = ""
        guard !name.isEmpty else { return }
        Task {
            do {
                try await WebDAVBackupStore.shared.createDirectory(named: name, at: currentPath)
                await load()
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    items = []
                    loading = false
                }
            }
        }
    }
}
