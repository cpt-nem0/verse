import AppKit

/// Which display the pill lives on. The decision is a *pure* function of
/// display IDs so the `--checks` runner can exercise it without a live
/// `NSScreen` (same rule as `PillLayout`).
///
/// The user's choice is persisted as a `CGDirectDisplayID` under
/// `verse.screenID` and only written when a screen is picked from the pill's
/// "Screen" menu. A preferred display that is currently disconnected simply
/// loses to the fallback — the preference is kept, so re-attaching that
/// display brings the pill back to it.
enum ScreenPicker {
    /// - Parameters:
    ///   - preferred: the user's saved display, `nil` if they never picked one.
    ///   - anchored: the display the saved pill position was captured on
    ///     (`PillAnchorRecord.screenID`) — hosting the panel there is what
    ///     makes the pill come back where it was parked.
    ///   - candidates: attached display IDs, in `NSScreen.screens` order.
    ///   - active: the display with the active menu bar (`NSScreen.main`).
    /// - Returns: the display to host the panel, `nil` only with no displays.
    static func resolve(
        preferred: CGDirectDisplayID?,
        anchored: CGDirectDisplayID?,
        candidates: [CGDirectDisplayID],
        active: CGDirectDisplayID?
    ) -> CGDirectDisplayID? {
        if let preferred, candidates.contains(preferred) { return preferred }
        if let anchored, candidates.contains(anchored) { return anchored }
        if let active, candidates.contains(active) { return active }
        return candidates.first
    }
}

extension NSScreen {
    /// This screen's hardware display ID (`NSScreenNumber`) — the only screen
    /// identity stable enough to persist across launches and re-plugs.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
