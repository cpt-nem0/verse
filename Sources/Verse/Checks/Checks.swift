#if DEBUG
import Foundation

/// Debug-only assertion harness. This machine has Command Line Tools only
/// (no XCTest / swift-testing), so tests live inside the app target and run
/// via `swift run Verse --checks` — see the plan's Global Constraints
/// (docs/superpowers/plans/2026-07-24-verse-pill-revamp.md, "Tests (AMENDED)").
private var checkFailures = 0

/// Prints `PASS name` / `FAIL name` and tracks failures for the final verdict.
func check(_ name: String, _ body: () -> Bool) {
    if body() {
        print("PASS \(name)")
    } else {
        print("FAIL \(name)")
        checkFailures += 1
    }
}

enum VerseChecks {
    /// Every checks file registers its entry point here
    /// (Sources/Verse/Checks/XChecks.swift -> runXChecks).
    private static let suites: [() -> Void] = [
        runTitleCleanerChecks,
        runEchoDetectionChecks,
        runPlaybackClockChecks,
        runFittedFontChecks,
        runPillLayoutChecks,
        runPillContentChecks,
        runMotionChecks,
        runAllowedSourcesChecks,
        runScreenPickerChecks
    ]

    /// When launched with `--checks`, runs every registered suite and exits
    /// 0 (all pass) or 1 (any failure). Must be called as the first statement
    /// of the app entry point, before any UI/AppKit setup.
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--checks") else { return }
        for suite in suites { suite() }
        if checkFailures == 0 {
            print("ALL CHECKS PASSED")
            exit(0)
        } else {
            print("\(checkFailures) CHECK(S) FAILED")
            exit(1)
        }
    }
}
#endif
