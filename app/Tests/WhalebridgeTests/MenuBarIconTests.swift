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

/// The icon reflects whether docker commands would actually work (daemon
/// running AND Apple's container services up), animates through transitions
/// we drive, and is dimmed for everything else.
@Suite struct MenuBarIconStateTests {
    @Test func activeOnlyWhenDaemonAndApiserverBothUp() {
        #expect(
            MenuBarIconState.forState(daemon: .running, apiserverRunning: true, apiserverTransitioning: false)
                == .active)
    }

    @Test func runningDaemonOverStoppedApiserverIsInactive() {
        #expect(
            MenuBarIconState.forState(daemon: .running, apiserverRunning: false, apiserverTransitioning: false)
                == .inactive)
    }

    @Test func daemonStartupAnimates() {
        #expect(
            MenuBarIconState.forState(daemon: .starting, apiserverRunning: false, apiserverTransitioning: false)
                == .animating)
    }

    @Test func apiserverStartOrRestartAnimatesRegardlessOfDaemonState() {
        for state: DaemonManager.State in [.stopped, .starting, .running, .waitingForRuntime] {
            #expect(
                MenuBarIconState.forState(daemon: state, apiserverRunning: false, apiserverTransitioning: true)
                    == .animating)
        }
    }

    @Test func everythingElseIsInactive() {
        for state: DaemonManager.State in [.stopped, .waitingForRuntime, .failed("boom")] {
            for apiserver in [true, false] {
                #expect(
                    MenuBarIconState.forState(
                        daemon: state, apiserverRunning: apiserver, apiserverTransitioning: false)
                        == .inactive)
            }
        }
    }
}
