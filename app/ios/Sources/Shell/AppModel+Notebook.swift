import UIKit

// Notebooks (D44): the editor pages show cells (a .ipynb, or a .py with
// `# %%`) and ask to run them; the engine runs them in a kernel (the session's
// interpreter, kept for the notebook) and sends their outputs back here, to
// every pane that has the notebook.

/// What a pane's editor reports about the file it shows.
struct NotebookPane: Equatable {
    let path: String
    /// "ipynb", "py" (cells in a .py), nil (no cells).
    let kind: String?
    let cells: Int
    /// A .ipynb's view: "notebook" or "source" (its JSON); a Markdown file's: "preview" or "source" (D46).
    let view: String?
}

/// input() in a cell waits for this alert.
struct NotebookPrompt {
    let title: String
    let alert: UIAlertController
    let reply: WebHost.Reply
}

extension AppModel {
    /// The notebook in the focused pane, if the current file has cells (or is a .ipynb).
    var notebook: NotebookPane? {
        guard let file, let n = notebookPanes[focused], n.path == file else { return nil }
        return n.kind != nil || file.hasSuffix(".ipynb") ? n : nil
    }

    var isIpynb: Bool { file?.hasSuffix(".ipynb") == true }

    func notebookEditorEvent(_ pane: Int, _ type: String, _ value: [String: Any]) {
        switch type {
        case "notebook":
            guard let path = value["path"] as? String else {
                notebookPanes[pane] = nil
                markdownViewChanged(pane, nil)
                return
            }
            let next = NotebookPane(path: path, kind: value["kind"] as? String, cells: value["cells"] as? Int ?? 0, view: value["view"] as? String)
            if notebookPanes[pane] != next { notebookPanes[pane] = next }
            markdownViewChanged(pane, isMarkdown(path) ? next.view : nil)
        case "runCells":
            guard let path = value["path"] as? String, !isExternal(path) else { return }
            let cells = value["cells"] ?? []
            let source = value["source"] as? String ?? ""
            Task {
                await saveAll() // sibling modules and data files are read from disk
                let started = await command("runCells", ["path": path, "cells": cells, "source": source]) as? Bool
                if started == false { showToast("Another program is running: stop it first") }
            }
        case "stop":
            stop()
        case "restartKernel":
            restartKernel(value["path"] as? String)
        case "openURL":
            // docs: links (in Markdown) open the Python docs (D37); the rest outside the app.
            guard let url = value["url"] as? String else { return }
            if let link = URL(string: url), openDocsLink(link) { return }
            Task { _ = await device.openURL(url) }
        case "openLocation":
            // A project file in a cell's traceback (D45), relative to the notebook's folder.
            guard let path = value["path"] as? String, let file = value["file"] as? String,
                  let target = ConsoleLinks.resolve(file, dir: dirname(path)) else { return }
            Task { await openLocation(target, line: value["line"] as? Int) }
        case "notebookError":
            showToast("Showing the file's JSON: \(value["message"] as? String ?? "it is no notebook")")
        default:
            break
        }
    }

    /// Outputs and states of a notebook's cells, for the panes that have it open.
    func notebookEvents(_ value: [String: Any]) {
        guard let path = value["path"] as? String, let events = value["events"] else { return }
        for i in editors.indices where panes.indices.contains(i) && panes[i].tabs.contains(path) {
            Task { _ = await editorCall(i, "notebookEvents", [path, events]) }
        }
    }

    func notebookCommand(_ name: String) {
        Task {
            let result = await editorCall(focused, "notebookCommand", [name])
            if let r = result as? [String: Any], r["ok"] as? Bool == false, let error = r["error"] as? String {
                showToast("Can't show it as a notebook: \(error)")
            } else if result as? Bool == false, name.hasPrefix("run") {
                showToast("Show the notebook to run its cells")
            }
        }
    }

    func restartKernel(_ path: String? = nil) {
        haptic()
        Task {
            _ = await command("restartKernel", ["path": path ?? file ?? ""])
            showToast("Kernel restarted")
        }
    }

    // MARK: input() in a cell

    func notebookInput(_ prompt: String, reply: @escaping WebHost.Reply) {
        answerNotebookPrompt(nil, dismiss: true) // one at a time
        let title = prompt.isEmpty ? "Input" : prompt
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.smartQuotesType = .no
            field.smartDashesType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.answerNotebookPrompt(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self, weak alert] _ in
            self?.answerNotebookPrompt(alert?.textFields?.first?.text ?? "")
        })
        notebookPrompt = NotebookPrompt(title: title, alert: alert, reply: reply)
        Modal.present(alert, from: { [weak self] in self?.host.presenter() }, failed: { [weak self, weak alert] in
            if let alert, self?.notebookPrompt?.alert === alert { self?.answerNotebookPrompt(nil) }
        })
    }

    /// nil: cancelled (EOFError in the cell).
    func answerNotebookPrompt(_ text: String?, dismiss: Bool = false) {
        guard let prompt = notebookPrompt else { return }
        notebookPrompt = nil
        if dismiss { Modal.dismiss(prompt.alert) }
        prompt.reply(text ?? NSNull(), nil)
    }
}
