#if canImport(UIKit) && canImport(QuickLook)
import UIKit
import QuickLook
import SwiftUI

/// QuickLook-based file preview and share sheet integration.
/// `open <file>` → QLPreviewController; `open .` → UIActivityViewController (share sheet).
public final class QuickLookHelper: NSObject {

    /// Preview a single file using QuickLook.
    /// - Parameter url: File URL to preview.
    /// - Parameter presenter: The view controller to present from.
    @MainActor
    public static func preview(url: URL, from presenter: UIViewController) {
        let controller = PreviewController()
        controller.item = url
        controller.dataSource = controller
        presenter.present(controller, animated: true)
    }

    /// Open share sheet for a file or directory.
    /// - Parameter url: The URL to share.
    /// - Parameter presenter: The view controller to present from.
    @MainActor
    public static func share(url: URL, from presenter: UIViewController) {
        let activity = UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
        )
        // iPad popover anchor
        if let popover = activity.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 0, height: 0
            )
        }
        presenter.present(activity, animated: true)
    }

    /// Handles the `open` command from the shell:
    /// - `open .` or `open <directory>` → share sheet
    /// - `open <file>` → QuickLook preview
    @MainActor
    public static func handleOpenCommand(path: String, from presenter: UIViewController) {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return }

        if isDir.boolValue {
            share(url: url, from: presenter)
        } else {
            preview(url: url, from: presenter)
        }
    }
}

// MARK: - Internal QLPreviewController subclass

private final class PreviewController: QLPreviewController, QLPreviewControllerDataSource {
    var item: URL?

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { item != nil ? 1 : 0 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        (item ?? URL(fileURLWithPath: "/dev/null")) as NSURL
    }
}

// MARK: - SwiftUI wrapper

/// SwiftUI view modifier that presents a QuickLook preview sheet.
public struct QuickLookModifier: ViewModifier {
    @Binding var url: URL?

    public func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { url != nil },
            set: { if !$0 { url = nil } }
        )) {
            if let url {
                QuickLookPreview(url: url)
                    .ignoresSafeArea()
            }
        }
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = PreviewController()
        controller.item = url
        controller.dataSource = controller
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
}

public extension View {
    /// Presents a QuickLook preview when the given URL binding is non-nil.
    func quickLookPreview(url: Binding<URL?>) -> some View {
        modifier(QuickLookModifier(url: url))
    }
}
#endif
