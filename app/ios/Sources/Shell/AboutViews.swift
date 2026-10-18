import SwiftUI

// Settings' About section: the version, the privacy policy, support and the
// acknowledgements (web/licenses.json, written by the web build from what is
// bundled, D51).

enum AppInfo {
    static let privacyPolicy = URL(string: "https://github.com/mitsuhiko/pyslopnista/blob/main/docs/privacy.md")!
    static let support = URL(string: "https://github.com/mitsuhiko/pyslopnista/issues")!

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

struct AboutSection: View {
    var body: some View {
        Section("About") {
            LabeledContent("Version", value: AppInfo.version)
            Link(destination: AppInfo.privacyPolicy) { Label("Privacy Policy", systemImage: "hand.raised") }
            Link(destination: AppInfo.support) { Label("Support", systemImage: "questionmark.bubble") }
            NavigationLink { AcknowledgementsView() } label: { Label("Acknowledgements", systemImage: "heart.text.square") }
        }
    }
}

private struct Acknowledgement: Decodable, Identifiable, Hashable {
    let name: String
    let version: String?
    let license: String
    let url: String?
    let docs: String? // a page of the bundled Python docs with the full text
    let text: String
    var id: String { name }
}

private struct Acknowledgements: Decodable {
    let builtIn: [Acknowledgement]
    let packages: [Acknowledgement]

    static func load() -> Acknowledgements? {
        let url = Bundle.main.resourceURL!.appendingPathComponent("web/licenses.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Acknowledgements.self, from: data)
    }
}

struct AcknowledgementsView: View {
    @State private var list = Acknowledgements.load()

    var body: some View {
        List {
            if let list {
                Section {
                    ForEach(list.builtIn) { row($0) }
                } footer: {
                    Text("Pyslopnista is built on these projects. Thank you to everyone who works on them.")
                }
                Section("Packages") {
                    ForEach(list.packages) { row($0) }
                }
            } else {
                Text("The list of acknowledgements is missing from this build.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ item: Acknowledgement) -> some View {
        NavigationLink {
            AcknowledgementView(item: item)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                Text([item.version, item.license].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AcknowledgementView: View {
    @Environment(AppModel.self) private var model
    let item: Acknowledgement

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let url = item.url.flatMap(URL.init(string:)) {
                    Link(item.url ?? "", destination: url).font(.footnote)
                }
                if let docs = item.docs {
                    Button {
                        model.showDocs(DocsTarget(version: model.defaultPython, ref: docs))
                    } label: {
                        Label("History and License", systemImage: "book")
                    }
                    .buttonStyle(.bordered)
                }
                Text(item.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
