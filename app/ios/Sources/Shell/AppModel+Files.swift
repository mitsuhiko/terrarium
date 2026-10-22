import QuickLook
import SwiftUI
import UIKit

// File management (D41): the Trash, moving files, Quick Look and sharing,
// favorites, and new files from templates.

/// A template for "New File": built in, or a file in Documents/Templates.
struct FileTemplate: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let fileExtension: String
    let content: String
}

extension AppModel {
    // MARK: Trash

    /// Delete from the browser or editor: into the Trash (Documents), or the
    /// provider's trash in a linked folder.
    func delete(_ path: String) async {
        let restorable: Bool
        do {
            restorable = try await host.onFileQueue { try $0.moveToTrash(path) }
        } catch {
            showToast("Could not delete: \(error)")
            return
        }
        deleted(path)
        showToast(restorable ? "Moved “\(basename(path))” to the Trash" : "Deleted “\(basename(path))”")
    }

    func trashItems() async -> [Trash.Item] {
        (try? await host.onFileQueue { $0.trash.items() }) ?? []
    }

    func restoreFromTrash(_ name: String) async {
        do {
            let path = try await host.onFileQueue { [root = host.files.root] in try $0.trash.restore(name, documents: root) }
            fileListVersion += 1
            showToast("Restored “\(basename(path))”")
        } catch {
            showToast("Could not restore: \(error)")
        }
    }

    func removeFromTrash(_ name: String) async {
        try? await host.onFileQueue { try $0.trash.remove(name) }
        fileListVersion += 1
    }

    func emptyTrash() async {
        try? await host.onFileQueue { try $0.trash.empty() }
        fileListVersion += 1
    }

    func purgeTrash() {
        Task { try? await host.onFileQueue { $0.trash.purge() } }
    }

    // MARK: moving

    /// Move a file or folder into another folder; returns its new path.
    @discardableResult
    func move(_ path: String, into folder: String) async -> String? {
        guard dirname(path) != folder else { return path }
        await saveAll()
        do {
            let to = try await host.onFileQueue { try $0.move(path, into: folder) }
            renamed(path, to)
            showToast("Moved to \(displayName(folder))")
            return to
        } catch {
            showToast("Could not move: \(error)")
            return nil
        }
    }

    /// Folders to move into, for the Move sheet: a folder's subfolders.
    func folders(in dir: String) async -> [String] {
        (try? await host.onFileQueue { files in
            try files.list(dir).filter { $0["dir"] as? Bool == true }.compactMap { $0["path"] as? String }
        }) ?? []
    }

    // MARK: Quick Look and sharing

    /// Files the editor can't show open in Quick Look.
    static func isPreviewable(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff", "pdf", "mp3", "m4a", "wav", "aif", "aiff",
                "caf", "mp4", "mov", "m4v", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "rtf", "usdz", "zip"].contains(ext)
    }

    /// A URL other apps can read: the file itself, or a copy of one in a linked folder.
    private func readableURL(_ path: String) async throws -> URL {
        try await host.onFileQueue { files in
            let (url, linked) = try files.locate(path)
            guard linked else { return url }
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
            let target = copy.appendingPathComponent(url.lastPathComponent)
            let data = try files.read(path, encoding: "base64")
            try Data(base64Encoded: data)?.write(to: target)
            return target
        }
    }

    func quickLook(_ path: String) {
        Task {
            guard let url = try? await readableURL(path) else { return showToast("Could not open “\(basename(path))”") }
            let source = PreviewSource(urls: [url])
            let ql = QLPreviewController()
            ql.dataSource = source
            objc_setAssociatedObject(ql, &PreviewSource.key, source, .OBJC_ASSOCIATION_RETAIN)
            Modal.present(ql, from: { [weak self] in self?.host.presenter() })
        }
    }

    func share(_ path: String) {
        Task {
            guard let url = try? await readableURL(path) else { return }
            let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            Modal.present(vc, from: { [weak self] in self?.host.presenter() }) // centered popover on iPad
        }
    }

    // MARK: favorites

    func isFavorite(_ path: String) -> Bool { favorites.contains(path) }

    func toggleFavorite(_ path: String) {
        if let i = favorites.firstIndex(of: path) { favorites.remove(at: i) } else { favorites.append(path) }
        UserDefaults.standard.set(favorites, forKey: "favorites")
        fileListVersion += 1
    }

    /// Favorites follow renames and moves, and go with deletions.
    func updateFavorites(renamed from: String? = nil, to: String? = nil, deleted: String? = nil) {
        var next = favorites
        if let from, let to {
            next = next.map { $0 == from || $0.hasPrefix(from + "/") ? to + $0.dropFirst(from.count) : $0 }
        }
        if let deleted { next.removeAll { $0 == deleted || $0.hasPrefix(deleted + "/") } }
        guard next != favorites else { return }
        favorites = next
        UserDefaults.standard.set(favorites, forKey: "favorites")
    }

    // MARK: templates

    static let builtinTemplates: [FileTemplate] = [
        FileTemplate(id: "empty", title: "Empty", subtitle: "An empty Python file", icon: "doc", fileExtension: "py", content: ""),
        FileTemplate(id: "script", title: "Script", subtitle: "Asks for input and prints", icon: "terminal", fileExtension: "py", content: """
            def main():
                name = input("What's your name? ")
                print(f"Hello, {name}!")


            if __name__ == "__main__":
                main()

            """),
        FileTemplate(id: "ui", title: "App", subtitle: "A native app with the ui module", icon: "iphone", fileExtension: "py", content: """
            # A small app: tap × to close it.
            import ui


            def App():
                count = ui.signal(0)
                return ui.Screen(
                    "My App",
                    ui.Text(lambda: f"Tapped {count()} times", font="title", text_align="center"),
                    ui.Button("Tap me", on_click=lambda: count.update(lambda n: n + 1)),
                )


            ui.run(App)

            """),
        FileTemplate(id: "turtle", title: "Turtle Drawing", subtitle: "Draw with the turtle", icon: "scribble.variable", fileExtension: "py", content: """
            import turtle

            t = turtle.Turtle()
            t.speed(0)
            colors = ["red", "orange", "gold", "green", "blue", "purple"]
            for i in range(120):
                t.pencolor(colors[i % len(colors)])
                t.forward(i * 2)
                t.left(59)

            turtle.done()

            """),
        FileTemplate(id: "plot", title: "Plot", subtitle: "A chart with matplotlib", icon: "chart.xyaxis.line", fileExtension: "py", content: """
            import matplotlib.pyplot as plt
            import numpy as np

            x = np.linspace(0, 2 * np.pi, 200)
            plt.plot(x, np.sin(x), label="sin")
            plt.plot(x, np.cos(x), label="cos")
            plt.legend()
            plt.title("Waves")
            plt.show()

            """),
        FileTemplate(id: "dialogs", title: "Dialogs", subtitle: "Ask with a form, answer with speech", icon: "list.bullet.rectangle", fileExtension: "py", content: """
            import console
            import dialogs
            import speech

            answers = dialogs.form_dialog("About You", [
                {"type": "text", "key": "name", "title": "Name", "placeholder": "Ada"},
                {"type": "switch", "key": "loud", "title": "Say it out loud", "value": True},
            ])
            if answers:
                greeting = f"Hello, {answers['name'] or 'stranger'}!"
                console.hud_alert(greeting)
                if answers["loud"]:
                    speech.say(greeting)

            """),
        FileTemplate(id: "deps", title: "Script with Packages", subtitle: "Dependencies from PyPI (PEP 723)", icon: "shippingbox", fileExtension: "py", content: """
            # /// script
            # dependencies = ["rich"]
            # ///
            from rich import print

            print("[bold magenta]Hello[/] from [green]rich[/]!")

            """),
        FileTemplate(id: "notebook", title: "Notebook", subtitle: "Cells of code and notes (Jupyter)", icon: "book.pages", fileExtension: "ipynb", content: #"""
            {
             "cells": [
              {
               "cell_type": "markdown",
               "id": "a1b2c3d4e5f6",
               "metadata": {},
               "source": [
                "# Notebook\n",
                "\n",
                "Run a cell with its ▶ button (or Shift-Return). What a cell defines stays for the cells after it."
               ]
              },
              {
               "cell_type": "code",
               "execution_count": null,
               "id": "b2c3d4e5f6a1",
               "metadata": {},
               "outputs": [],
               "source": [
                "name = \"world\"\n",
                "f\"Hello, {name}!\""
               ]
              }
             ],
             "metadata": {
              "kernelspec": {
               "display_name": "Python 3",
               "language": "python",
               "name": "python3"
              },
              "language_info": {
               "name": "python"
              }
             },
             "nbformat": 4,
             "nbformat_minor": 5
            }

            """#),
        FileTemplate(id: "markdown", title: "Notes", subtitle: "A Markdown file", icon: "text.alignleft", fileExtension: "md", content: "# Notes\n\n"),
    ]

    /// Your own templates: the files in Documents/Templates.
    func userTemplates() async -> [FileTemplate] {
        let paths = (try? await host.onFileQueue { files -> [String] in
            guard (try? files.exists("Templates")) == true else { return [] }
            return try files.list("Templates").filter { $0["dir"] as? Bool != true }.compactMap { $0["path"] as? String }
        }) ?? []
        var out: [FileTemplate] = []
        for path in paths {
            guard let text = try? await host.onFileQueue({ try $0.read(path, encoding: "utf8") }) else { continue }
            let name = basename(path)
            let ext = (name as NSString).pathExtension
            out.append(FileTemplate(id: "user:\(path)", title: (name as NSString).deletingPathExtension, subtitle: "Templates/\(name)",
                                    icon: "doc.badge.gearshape", fileExtension: ext.isEmpty ? "py" : ext, content: text))
        }
        return out
    }

    /// A new file from a template; returns its path.
    func newFile(in dir: String, name: String, template: FileTemplate) async -> String? {
        var trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return nil }
        if (trimmed as NSString).pathExtension.isEmpty { trimmed += ".\(template.fileExtension)" }
        let path = joinPath(dir, trimmed)
        if (try? await host.onFileQueue({ try $0.exists(path) })) == true {
            showToast("“\(trimmed)” already exists")
            return nil
        }
        do {
            try await host.onFileQueue { try $0.write(path, data: template.content, encoding: "utf8") }
        } catch {
            showToast("Could not create the file: \(error)")
            return nil
        }
        fileListVersion += 1
        return path
    }
}
