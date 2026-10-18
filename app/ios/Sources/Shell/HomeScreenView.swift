import SwiftUI

/// "Add to Home Screen" for a program (D38). Apps can't put icons on the
/// Home Screen themselves; the Shortcuts app can, with our "Run Python
/// Program" action. This sheet walks through it and offers the program's
/// terrarium:// link for an "Open URL" action.
struct HomeScreenView: View {
    let path: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var name: String { (basename(path) as NSString).deletingPathExtension }
    private var link: URL { LaunchAction.run(path).url }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "play.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 60, height: 60)
                            .background(LinearGradient(colors: [.blue, .indigo], startPoint: .top, endPoint: .bottom),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name).font(.headline)
                            Text("Opens Terrarium and runs \(basename(path)).").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("iOS lets only the Shortcuts app put icons on the Home Screen. Make a shortcut that runs the program, then add it there.")
                }
                Section("In Shortcuts") {
                    step(1, "Tap **Open Shortcuts** below. A new shortcut opens.")
                    step(2, "Tap **Add Action**, search for **Terrarium** and choose **Run Python Program**.")
                    step(3, "Tap **Program** and pick **\(name)**.")
                    step(4, "Tap the name at the top, rename it to **\(name)** and choose **Add to Home Screen**. There you can also pick an icon.")
                }
                Section {
                    Button {
                        openURL(URL(string: "shortcuts://create-shortcut")!)
                    } label: {
                        Label("Open Shortcuts", systemImage: "square.2.layers.3d")
                    }
                    Button {
                        UIPasteboard.general.url = link
                        model.showToast("Link copied")
                    } label: {
                        Label("Copy Link", systemImage: "link")
                    }
                } footer: {
                    Text("The link runs the program too, from an **Open URL** action or anywhere else links open: \(link.absoluteString)")
                }
            }
            .navigationTitle("Add to Home Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Circle().fill(Color.accentColor))
            Text(text).font(.subheadline)
        }
    }
}
