#if DEBUG
import AppKit

/// Multi-screen resolution: the display the pill parks on, given the saved
/// preference, the attached displays and the one with the active menu bar.
func runScreenPickerChecks() {
    let a: CGDirectDisplayID = 1
    let b: CGDirectDisplayID = 2
    let c: CGDirectDisplayID = 3

    check("ScreenPicker: saved display wins while attached") {
        ScreenPicker.resolve(preferred: b, anchored: nil, candidates: [a, b], active: a) == b
    }
    check("ScreenPicker: an explicit pick beats the parked position's display") {
        ScreenPicker.resolve(preferred: b, anchored: a, candidates: [a, b], active: a) == b
    }
    check("ScreenPicker: the parked position's display beats the active one") {
        ScreenPicker.resolve(preferred: nil, anchored: b, candidates: [a, b], active: a) == b
    }
    check("ScreenPicker: an unplugged parked display falls back to the active one") {
        ScreenPicker.resolve(preferred: nil, anchored: c, candidates: [a, b], active: b) == b
    }
    check("ScreenPicker: a legacy anchor (no display recorded) uses the active one") {
        ScreenPicker.resolve(preferred: nil, anchored: nil, candidates: [a, b], active: b) == b
    }
    check("ScreenPicker: unplugged preference falls back to the active display") {
        ScreenPicker.resolve(preferred: c, anchored: nil, candidates: [a, b], active: b) == b
    }
    check("ScreenPicker: preference survives the fallback and wins on re-plug") {
        ScreenPicker.resolve(preferred: c, anchored: a, candidates: [a, b, c], active: a) == c
    }
    check("ScreenPicker: unknown active display falls back to the first screen") {
        ScreenPicker.resolve(preferred: nil, anchored: nil, candidates: [a, b], active: c) == a
    }
    check("ScreenPicker: no displays resolves to nil") {
        ScreenPicker.resolve(preferred: a, anchored: a, candidates: [], active: a) == nil
    }
}
#endif
