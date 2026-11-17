import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Cross-platform clipboard access (UIPasteboard on iOS, NSPasteboard on macOS).
enum Clipboard {
    static var string: String? {
        get {
            #if os(macOS)
            NSPasteboard.general.string(forType: .string)
            #else
            UIPasteboard.general.string
            #endif
        }
        set {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
            #else
            UIPasteboard.general.string = newValue
            #endif
        }
    }
}

/// Semantic colors that map to the closest equivalent on each platform.
extension Color {
    static var appGroupedBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(.systemGroupedBackground)
        #endif
    }

    static var appSecondaryBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(.secondarySystemBackground)
        #endif
    }

    static var appTertiaryBackground: Color {
        #if os(macOS)
        Color(nsColor: .underPageBackgroundColor)
        #else
        Color(.tertiarySystemBackground)
        #endif
    }

    static var appSeparator: Color {
        #if os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color(.separator)
        #endif
    }
}

extension View {
    /// Disables autocapitalization and applies the URL keyboard where those exist (iOS only).
    @ViewBuilder
    func urlFieldStyle() -> some View {
        #if os(macOS)
        self.autocorrectionDisabled()
        #else
        self.keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #endif
    }

    /// Gives the Settings sheet a usable size on macOS, where a sheet otherwise
    /// shrinks to its minimum and clips the form's labels.
    @ViewBuilder
    func settingsSheetFrame() -> some View {
        #if os(macOS)
        self.frame(minWidth: 560, idealWidth: 620, minHeight: 640, idealHeight: 760)
        #else
        self
        #endif
    }

    /// Disables autocapitalization where it exists (iOS only).
    @ViewBuilder
    func noAutocapitalization() -> some View {
        #if os(macOS)
        self
        #else
        self.textInputAutocapitalization(.never)
        #endif
    }

    /// Inline navigation title on iOS; a no-op on macOS.
    @ViewBuilder
    func inlineNavigationTitle() -> some View {
        #if os(macOS)
        self
        #else
        self.navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
