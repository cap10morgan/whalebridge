import AppKit
import Testing

@testable import Whalebridge

/// MenuBarIcon.load falls back to a system symbol when a PNG is missing from
/// the resource bundle; the fallback's size is the symbol's natural size, so
/// asserting 18×18 catches a broken or incomplete resource bundle.
@MainActor
@Suite struct MenuBarIconTests {
    @Test func shipsAllAnimationFrames() {
        #expect(MenuBarIcon.startingFrames.count == 12)
        for frame in MenuBarIcon.startingFrames {
            #expect(frame.size == NSSize(width: 18, height: 18))
        }
    }

    @Test func staticGlyphsComeFromTheResourceBundle() {
        #expect(MenuBarIcon.running.size == NSSize(width: 18, height: 18))
        #expect(MenuBarIcon.stopped.size == NSSize(width: 18, height: 18))
        #expect(MenuBarIcon.running.isTemplate)
        #expect(MenuBarIcon.stopped.isTemplate)
    }
}
