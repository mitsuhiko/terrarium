import SwiftUI

// File management views (D41): the Trash, "New File" with templates, and
// "Move…" with a folder picker.

/// Deleted files and folders from Documents; restore them or delete them for good.
struct TrashView: View {
    @Environment(AppModel.self) private var model
    @State private var items: [Trash.Item]?
    @State private var emptying = false
    @Environment(\.inSidebar) private var inSidebar

    var body: some View {
        Group {
            if inSidebar {
                // The sidebar's own header (D61), not a navigation bar.
                VStack(spacing: 0) {
                    SidebarHeader(title: "Trash") { emptyButton.padding(.trailing, 6) }
                    list.contentMargins(.top, 8, for: .scrollContent).contentMargins(.horizontal, 12, for: .scrollContent)
                }
            } else {
                list
                    .navigationTitle("Trash")
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { emptyButton } }
            }
        }
        .confirmationDialog("Delete everything in the Trash?", isPresented: $emptying, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { Task { await model.emptyTrash() } }
        } message: {
            Text("This cannot be undone.")
        }
        .task(id: model.fileListVersion) { items = await model.trashItems() }
    }

    private var emptyButton: some View {
        Button("Empty", role: .destructive) { emptying = true }.disabled(items?.isEmpty ?? true)
    }

    private var list: some View {
        List {
            if let items {
                if items.isEmpty {
                    ContentUnavailableView("Trash Is Empty", systemImage: "trash", description: Text("Deleted files stay here for \(Int(Trash.keepDays)) days."))
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(items, id: \.name) { item in row(item) }
                    } footer: {
                        Text("Items are deleted for good after \(Int(Trash.keepDays)) days.")
                    }
                }
            }
        }
    }

    private func row(_ item: Trash.Item) -> some View {
        HStack(spacing: 12) {
            Group { if item.isDirectory { FolderIcon() } else { FileIcon(name: item.name) } }.frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text((item.original as NSString).lastPathComponent).lineLimit(1)
                Text("From \(dirname(item.original).isEmpty ? "Files" : dirname(item.original)) · \(item.deleted.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { Task { await model.removeFromTrash(item.name) } } label: { Label("Delete", systemImage: "trash") }
            Button { Task { await model.restoreFromTrash(item.name) } } label: { Label("Restore", systemImage: "arrow.uturn.backward") }.tint(.blue)
        }
        .contextMenu {
            Button { Task { await model.restoreFromTrash(item.name) } } label: { Label("Put Back", systemImage: "arrow.uturn.backward") }
            Button(role: .destructive) { Task { await model.removeFromTrash(item.name) } } label: { Label("Delete Now", systemImage: "trash") }
        }
    }
}

/// A new file: a name and a template (built in, or from Documents/Templates).
struct NewFileView: View {
    let dir: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = "untitled"
    @State private var template = AppModel.builtinTemplates[0]
    @State private var custom: [FileTemplate] = []
    @FocusState private var naming: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Name", text: $name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($naming)
                            .onSubmit(create)
                        if (name as NSString).pathExtension.isEmpty {
                            Text(".\(template.fileExtension)").foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("In \(displayName(dir)).")
                }
                Section("Template") {
                    ForEach(AppModel.builtinTemplates) { option($0) }
                }
                Section {
                    ForEach(custom) { option($0) }
                } header: {
                    Text("Your Templates")
                } footer: {
                    Text("Files in the Templates folder (in Files) show up here.")
                }
            }
            .navigationTitle("New File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Create", action: create).fontWeight(.semibold).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
        }
        .task {
            custom = await model.userTemplates()
            naming = true
        }
    }

    private func option(_ t: FileTemplate) -> some View {
        Button { template = t } label: {
            HStack(spacing: 12) {
                Image(systemName: t.icon).frame(width: 28).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).foregroundStyle(.primary)
                    Text(t.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if t.id == template.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).fontWeight(.semibold) }
            }
        }
        .tint(.primary)
    }

    private func create() {
        let (dir, name, template) = (dir, name, template)
        Task {
            guard let path = await model.newFile(in: dir, name: name, template: template) else { return }
            dismiss()
            await model.openFile(path)
        }
    }
}

/// "Move…": pick the folder a file or folder goes to.
struct MoveView: View {
    let path: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var trail: [String] = []

    var body: some View {
        NavigationStack(path: $trail) {
            FolderPicker(dir: "", moving: path, done: move)
                .navigationDestination(for: String.self) { FolderPicker(dir: $0, moving: path, done: move) }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func move(_ folder: String) {
        Task {
            await model.move(path, into: folder)
            dismiss()
        }
    }
}

private struct FolderPicker: View {
    let dir: String
    let moving: String
    let done: (String) -> Void
    @Environment(AppModel.self) private var model
    @State private var folders: [String]?

    private var here: Bool { dirname(moving) == dir }

    var body: some View {
        List {
            Section {
                ForEach(folders ?? [], id: \.self) { folder in
                    NavigationLink(value: folder) {
                        Label { Text(displayName(folder)) } icon: { if isLocationRoot(folder) { Image(systemName: "externaldrive.connected.to.line.below") } else { FolderIcon() } }
                    }
                    .disabled(folder == moving)
                }
                if folders?.isEmpty == true { Text("No folders").foregroundStyle(.secondary) }
            } header: {
                Text("Move “\(basename(moving))” to")
            }
        }
        .navigationTitle(displayName(dir))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button { done(dir) } label: {
                Text(here ? "Already Here" : "Move Here").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(here || dir == moving || dir.hasPrefix(moving + "/"))
            .padding()
            .background(.bar)
        }
        .task {
            var list = await model.folders(in: dir)
            if dir.isEmpty {
                list += model.host.files.locations.list().compactMap { $0["available"] as? Bool == true ? $0["path"] as? String : nil }
            }
            folders = list
        }
    }
}
