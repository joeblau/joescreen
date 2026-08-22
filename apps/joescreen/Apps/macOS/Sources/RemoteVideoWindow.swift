import SwiftUI
import Observation
import JoeScreenKit
import JoeScreenLiveKit
import LiveKit

/// Model for one remote shared window rendered as a native NSWindow (spec §3 / M4 / M9). Observable
/// so owner-color chrome, the aspect ratio, and the pause/reconnecting overlay all recolor/relayout
/// live when the room repairs owner attribution or the media state changes — without rebuilding the
/// hosting view. Holds the LiveKit remote track (swappable on reopen / codec renegotiation).
@MainActor
@Observable
public final class RemoteVideoWindow: Identifiable {
    public nonisolated let windowID: WindowID
    /// The owning participant. Starts as a placeholder (descriptor identity or the windowID) and is
    /// REPAIRED by every authoritative RoomModel snapshot (`applyRoom`), so a track that subscribed
    /// before the first snapshot recolors/retitles correctly once the snapshot lands (latent bug #5).
    public var ownerID: ParticipantID
    /// The live remote video track. `var` so reopen / codec renegotiation swaps a new track into the
    /// SAME window (no duplicate window). Views observe this and re-attach the renderer.
    public var track: RemoteVideoTrackRef
    /// Source aspect ratio (w/h) for aspect-true sizing; nil until dimensions are known (fallback).
    public var aspectRatio: Double?
    /// Advisory title/app for the window chrome (from ShareInfo).
    public var title: String?
    public var appName: String?
    /// Whether the share is paused (owner minimized/occluded/paused) — drives a "Paused" badge.
    public var isPaused: Bool = false
    /// Whether the media link is reconnecting — drives a "Reconnecting…" overlay over the frozen frame.
    public var isReconnecting: Bool = false
    /// Soft-visibility: when false, the SwiftUIVideoView is detached (adaptive-stream stops the SFU
    /// forwarding); a placeholder keeps the aspect. Set by the lifecycle's pause/resumeRendering.
    public var isRenderingActive: Bool = true

    public init(windowID: WindowID, ownerID: ParticipantID, track: RemoteVideoTrackRef,
                aspectRatio: Double? = nil, title: String? = nil, appName: String? = nil) {
        self.windowID = windowID
        self.ownerID = ownerID
        self.track = track
        self.aspectRatio = aspectRatio
        self.title = title
        self.appName = appName
    }

    public nonisolated var id: WindowID { windowID }
}

/// The SwiftUI content of a remote window: the live `SwiftUIVideoView` (aspect-fitted) with an
/// owner-color border, a per-participant cursor overlay (M6), and pause/reconnecting overlays (M9).
/// Cursor coordinates map through `VideoFitMath` so a letterboxed video aligns pointer↔pixel at
/// both ends (fixes the cursor-drift bug). Local resizing is a pure display transform — the
/// normalized value is invariant (spec §3.4).
struct RemoteVideoView: View {
    let window: RemoteVideoWindow
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                // The live remote video, only while rendering is active. Detaching it (soft-hide)
                // makes adaptive-stream stop the SFU forwarding (R24/R32); a placeholder keeps aspect.
                if window.isRenderingActive {
                    VideoSurface(track: window.track, layoutMode: .fit)
                        .ignoresSafeArea()
                }
                // Annotation ink overlay (F9): every participant's strokes; captures local strokes in
                // draw mode. Mapped through the same VideoFitMath content rect so ink aligns per-pixel.
                DrawOverlay(windowID: window.windowID, size: geo.size, videoAspect: window.aspectRatio)
                // Per-window cursor overlay for every remote participant (M6), mapped through the
                // same VideoFitMath content rect so overlay glyphs sit on the right pixel.
                CursorOverlay(windowID: window.windowID, size: geo.size,
                              videoAspect: window.aspectRatio)
                // Pause / reconnecting state badges (state already broadcast; surfaced here in M9).
                overlayBadges
                // Draw toolbar (F9): toggle draw mode, undo, clear the local author's ink.
                DrawToolbar(windowID: window.windowID)
            }
            .overlay(
                Rectangle()
                    .strokeBorder(model.color(for: window.ownerID), lineWidth: 3))
            // Outbound cursor (M6): report the LOCAL user's pointer over this remote window in
            // CONTENT-normalized [0,1] coords (relative to the video, not the letterboxed view), so
            // peers place it on the same pixel feature (§3.4). VideoFitMath clamps off-video hovers.
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    let point = VideoFitMath.normalizedPoint(
                        fromViewPoint: location,
                        videoAspect: window.aspectRatio ?? Double(geo.size.width / max(geo.size.height, 1)),
                        viewSize: geo.size)
                    model.reportLocalCursor(windowID: window.windowID, point: point)
                case .ended:
                    break
                }
            }
        }
    }

    @ViewBuilder private var overlayBadges: some View {
        VStack {
            HStack {
                if window.isReconnecting {
                    badge("Reconnecting…", systemImage: "arrow.triangle.2.circlepath", tint: .orange)
                } else if window.isPaused {
                    badge("Paused", systemImage: "pause.circle.fill", tint: .yellow)
                }
                Spacer()
            }
            Spacer()
        }
        .padding(10)
        .allowsHitTesting(false)
    }

    private func badge(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint.opacity(0.9), in: Capsule())
    }
}
