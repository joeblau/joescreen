import SwiftUI
import LiveKit

/// The app-standard live video surface: LiveKit's `SwiftUIVideoView` pinned to the sample-buffer
/// renderer. Every video surface in the app (remote share windows, grid thumbnails, face tiles,
/// PiP, self-preview) must go through this wrapper rather than `SwiftUIVideoView` directly.
///
/// Why: the SDK default (`renderMode: .auto`) resolves to the Metal renderer (`RTCMTLNSVideoView`),
/// whose MTKView runs a 60 Hz display-link and — on macOS — re-renders the LAST frame every vsync
/// even when no new frame arrived. That is a constant per-surface CPU/GPU tax (a `sample` of 0.5.0
/// in a quiet call showed MTKView draw as most of the main thread's work), multiplied by however
/// many surfaces are on screen. `AVSampleBufferDisplayLayer` instead does work only when a frame is
/// enqueued and hands WindowServer an IOSurface to composite, so a static screen share costs
/// ~nothing between frames and each surface scales with its track's real frame rate.
struct VideoSurface: View {
    let track: VideoTrack
    var layoutMode: VideoView.LayoutMode = .fill
    var mirrorMode: VideoView.MirrorMode = .auto

    /// macOS 27 enforces that nothing dirties Auto Layout constraints during the window's
    /// display-cycle flush. The sample-buffer `VideoView` does exactly that while SwiftUI queries
    /// its layout traits mid-`NSHostingView.layout` (the surface appears with a move transition →
    /// `AppKitPlatformViewHost.coreLayoutTraits` → `updateConstraintsForSubtreeIfNeeded` →
    /// NSISEngine change notification → `_postWindowNeedsUpdateConstraints` throws
    /// NSInternalInconsistencyException), killing the app the moment a call's video tiles appear.
    /// Until the attach path is safe there, fall back to the SDK-default Metal renderer on 27+ and
    /// keep the idle-CPU win everywhere the sample-buffer path is known-good.
    private static let renderMode: VideoView.RenderMode = {
        if #available(macOS 27, *) { return .auto }
        return .sampleBuffer
    }()

    var body: some View {
        SwiftUIVideoView(track, layoutMode: layoutMode, mirrorMode: mirrorMode,
                         renderMode: Self.renderMode)
    }
}
