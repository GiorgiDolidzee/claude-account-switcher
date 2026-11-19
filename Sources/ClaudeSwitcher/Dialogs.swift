import AppKit

@MainActor
enum Dialogs {
    /// Shows an alert and returns the index of the button that was clicked.
    @discardableResult
    static func ask(_ title: String, _ text: String = "", buttons: [String] = ["OK"], style: NSAlert.Style = .informational) -> Int {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = style
        for button in buttons { alert.addButton(withTitle: button) }
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    static func info(_ title: String, _ text: String = "") { ask(title, text) }

    /// Asks for a line of text. Returns nil on Cancel.
    static func prompt(_ title: String, text: String, value: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
