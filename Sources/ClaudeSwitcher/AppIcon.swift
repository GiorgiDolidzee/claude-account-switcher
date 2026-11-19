import AppKit

enum AppIcon {
    /// The app's own icon from its bundle; a plain symbol when running unbundled.
    @MainActor static var image: NSImage {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            return icon
        }
        return NSImage(systemSymbolName: "arrow.left.arrow.right.circle.fill", accessibilityDescription: nil) ?? NSImage()
    }
}
