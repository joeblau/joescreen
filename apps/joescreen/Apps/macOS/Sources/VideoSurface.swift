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

    var body: some View {
        SwiftUIVideoView(track, layoutMode: layoutMode, mirrorMode: mirrorMode,
                         renderMode: .sampleBuffer)
    }
}
