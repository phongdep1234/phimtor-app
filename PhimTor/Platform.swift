import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Các chỗ khác nhau giữa iPhone và Mac
enum Plat {
    static func open(_ u: URL) {
        #if os(iOS)
        UIApplication.shared.open(u)
        #else
        NSWorkspace.shared.open(u)
        #endif
    }
    static func paste() -> String? {
        #if os(iOS)
        UIPasteboard.general.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }
    static func copy(_ s: String) {
        #if os(iOS)
        UIPasteboard.general.string = s
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #endif
    }
    static func keepAwake(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #else
        Sleep.set(on)
        #endif
    }
}

#if os(macOS)
import IOKit.pwr_mgt
enum Sleep {
    private static var id: IOPMAssertionID = 0
    static func set(_ on: Bool) {
        if on, id == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "PhimTor đang phát phim" as CFString, &id)
        } else if !on, id != 0 {
            IOPMAssertionRelease(id); id = 0
        }
    }
}
#endif

extension View {
    func inlineTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
    func plainInput(url: Bool = false) -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(url ? .URL : .default)
        #else
        self.autocorrectionDisabled()
        #endif
    }
    func alwaysSearchable(_ text: Binding<String>, prompt: String) -> some View {
        #if os(iOS)
        self.searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
        #else
        self.searchable(text: text, placement: .toolbar, prompt: prompt)
        #endif
    }
    func playerChrome() -> some View {
        #if os(iOS)
        self.statusBarHidden(true).persistentSystemOverlays(.hidden)
        #else
        self
        #endif
    }
}
