import SwiftUI

struct LicenseNotice: Identifiable, Hashable {
    let id: String
    let title: String
    let text: String
}

enum LicenseNoticeLoader {
    static func load(from bundle: Bundle = .main) -> [LicenseNotice] {
        let urls = bundle.urls(forResourcesWithExtension: "txt", subdirectory: "NOTICES") ?? []
        return urls
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let stem = url.deletingPathExtension().lastPathComponent
                return LicenseNotice(id: stem, title: displayTitle(stem), text: text)
            }
    }

    /// `SwiftTerm-MIT` → `SwiftTerm (MIT)`; `JetBrainsMono-OFL` → `JetBrainsMono (OFL)`.
    private static func displayTitle(_ stem: String) -> String {
        guard let dash = stem.lastIndex(of: "-"), dash > stem.startIndex else { return stem }
        let name = String(stem[..<dash])
        let license = String(stem[stem.index(after: dash)...])
        return "\(name) (\(license))"
    }
}

struct LicensesView: View {
    private let notices = LicenseNoticeLoader.load()

    var body: some View {
        List(notices) { notice in
            NavigationLink(notice.title) {
                ScrollView {
                    Text(notice.text)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                }
                .navigationTitle(notice.title)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .navigationTitle("Licenses")
        .overlay {
            if notices.isEmpty {
                Text("No license notices found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
