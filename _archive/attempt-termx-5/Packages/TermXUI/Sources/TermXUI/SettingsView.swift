import SwiftUI

public struct TermXSettingsView: View {
    public init() {}
    public var body: some View {
        Form {
            Section("Terminal") { Text("TermX uses a workspace-scoped terminal session."); Text("Theme: Dark"); Text("Terminal: xterm-256color") }
            Section("Privacy") { Text("TermX stores workspace bookmarks and terminal state locally. Network access is only used by commands or integrations explicitly started by the user.") }
            Section("Licenses") { NavigationLink("Open third-party notices") { TermXLicensesView() } }
        }.navigationTitle("Settings")
    }
}

public struct TermXLicensesView: View {
    public init() {}
    public var body: some View {
        List {
            LicenseRow(name: "SwiftTerm", license: "MIT")
            LicenseRow(name: "ios_system / BSD command ports", license: "BSD-3-Clause")
            LicenseRow(name: "CPython", license: "Python Software Foundation License")
            LicenseRow(name: "Node.js / nodejs-mobile", license: "MIT")
            LicenseRow(name: "WASM runtime", license: "MIT / Apache-2.0")
            LicenseRow(name: "Blink compatibility engine", license: "ISC")
            LicenseRow(name: "JetBrains Mono / Fira Code", license: "SIL Open Font License")
            Text("TermX does not redistribute the Claude Code npm package or Alpine packages. Those are obtained by the user under their own applicable terms.").font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("Licenses")
    }
}

private struct LicenseRow: View {
    let name: String; let license: String
    var body: some View { VStack(alignment: .leading, spacing: 3) { Text(name).font(.headline); Text(license).font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 4) }
}
