import SwiftUI
import AppKit

// Simple paste helper - reads from system clipboard
func clipboardContent() -> String? {
    NSPasteboard.general.string(forType: .string)
}
