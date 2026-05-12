import Cocoa

/// Renders a raster image from a file path into a panel. Uses an
/// `NSImageView` directly — skips the WKWebView base class — because:
/// - HiDPI rendering / image-rep selection happens natively.
/// - Big files don't melt the web process; AppKit's image-rep machine
///   does proper tile-based decode.
/// - The PRD's snapshot return value for `show_image` is *the image
///   itself*, not a screenshot — so we cache the original bytes from
///   the path and return them directly.
@MainActor
final class ImageRenderer: NSObject, PanelRenderer {
    static var typeKey: String { "image" }

    private let imageView = NSImageView()
    private(set) var lastImageData: Data?
    private(set) var lastImageSize: CGSize = .zero

    override init() {
        super.init()
    }

    func makeView() -> NSView {
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        // Magnification via two-finger pinch lands in Phase 5 polish.
        return imageView
    }

    func update(payload: PanelPayload) async throws -> RenderResult {
        guard payload.form == "path" else {
            throw RenderFailure(
                message: "show_image only supports `form: path` in v0.1",
                line: nil
            )
        }
        let url = URL(fileURLWithPath: payload.body)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RenderFailure(
                message: "failed to read image at '\(payload.body)': \(error.localizedDescription)",
                line: nil
            )
        }
        guard let image = NSImage(data: data) else {
            throw RenderFailure(
                message: "couldn't decode image at '\(payload.body)' (corrupt or unsupported format)",
                line: nil
            )
        }
        imageView.image = image
        lastImageData = data
        lastImageSize = image.size
        return RenderResult(width: Double(image.size.width), height: Double(image.size.height))
    }

    func snapshot() async throws -> Data {
        // The PRD specifies that show_image returns the image *bytes
        // themselves*, not a snapshot of the rendered panel. Cached
        // from the last update.
        if let data = lastImageData {
            return data
        }
        return try SnapshotService.snapshotView(imageView)
    }
}
