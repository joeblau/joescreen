import AppKit
import JoeScreenKit

/// Where on the local screen a locally-shared window/display currently sits — the ink target.
enum InkTarget: Sendable, Equatable {
    case window(CGWindowID)
    case display(CGDirectDisplayID)
}

/// Sharer-side remote-ink overlay (F9): peers' strokes land in `DrawModel` on every machine, but
/// without this manager they only render inside VIEWER surfaces (the remote video window and the
/// share-grid thumbnails) — the sharer never saw the ink on the actual window being pointed at.
///
/// For every locally shared window/display that holds ink, this floats a borderless,
/// click-through, non-activating NSWindow exactly over the real window and paints the strokes
/// with the same geometry the peer-side SwiftUI Canvas uses (`VideoFitMath`, round-capped
/// polylines in the author's color). Like ShareBorderOverlay, our own windows are excluded from
/// the capture filter, so the ink is never baked into the outgoing video (peers would see double).
///
/// Driven two ways: `sync()` on every DrawModel change (pump `onChange`), and a 4 Hz self-poll
/// while any overlay is visible — the poll picks up 15 s ink expiry (which mutates the model
/// without a pump callback) and tracks the target window's frame as it moves.
@MainActor
final class RemoteInkOverlayManager {
    /// Live sources, installed by AppModel. Pulled by the poll so expiry (which bypasses the
    /// pump) is reflected without storing a stale value-type copy of the model.
    var providers: (() -> (ink: DrawModel, targets: [WindowID: InkTarget]))?

    private var overlays: [WindowID: NSWindow] = [:]
    private var pollTask: Task<Void, Never>?

    /// Reconcile overlays with the current ink/targets. Idempotent; safe to call at poll cadence.
    func sync() {
        guard let providers else { return }
        let (ink, targets) = providers()
        let inkingWindows = Set(ink.windowsWithInk).intersection(targets.keys)

        for (id, window) in overlays where !inkingWindows.contains(id) {
            window.orderOut(nil)
            overlays[id] = nil
        }

        for id in inkingWindows {
            guard let target = targets[id], let frame = Self.frame(for: target) else {
                // Target off-screen (minimized/occluded): keep the entry, just hide — ink may
                // outlive a transient minimize.
                overlays[id]?.orderOut(nil)
                continue
            }
            let overlay = overlays[id] ?? Self.makeOverlay()
            overlays[id] = overlay
            let frameChanged = overlay.frame != frame
            if frameChanged { overlay.setFrame(frame, display: false) }
            // The 4 Hz poll mostly finds nothing changed — repaint only on a real frame move or
            // stroke set change, and don't re-front an overlay that is already ordered in.
            if let view = overlay.contentView as? InkOverlayView {
                let strokes = ink.strokes(in: id)
                if frameChanged || view.strokes != strokes {
                    view.strokes = strokes
                    view.needsDisplay = true
                }
            }
            if !overlay.isVisible { overlay.orderFrontRegardless() }
        }

        overlays.isEmpty ? stopPolling() : startPolling()
    }

    /// Drop every overlay and stop polling (leave/teardown).
    func hideAll() {
        for (_, window) in overlays { window.orderOut(nil) }
        overlays.removeAll()
        stopPolling()
    }

    // MARK: - Polling (frame tracking + expiry pickup while ink is visible)

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.sync()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Windows

    private static func makeOverlay() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = .floating              // above the shared (normal-level) window
        w.backgroundColor = .clear
        w.isOpaque = false
        w.ignoresMouseEvents = true      // click-through: never intercepts the sharer's input
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.contentView = InkOverlayView()
        return w
    }

    /// The AppKit frame covering the ink target, or nil when the window is off-screen.
    private static func frame(for target: InkTarget) -> NSRect? {
        switch target {
        case .window(let cgWindowID):
            guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], cgWindowID) as? [[String: Any]],
                  let bounds = list.first?[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
                  let w = bounds["Width"] as? Double, let h = bounds["Height"] as? Double else {
                return nil
            }
            // CGWindowList bounds are top-left origin; NSWindow frames live in the AppKit global
            // space whose origin is the PRIMARY display's bottom-left (same rule ShareBorderOverlay
            // documents for displays).
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            return NSRect(x: x, y: primaryHeight - y - h, width: w, height: h)
        case .display(let displayID):
            return ShareBorderOverlay.appKitFrame(for: displayID)
        }
    }
}

/// Paints committed strokes (all authors) as round-capped polylines in author colors — the same
/// geometry as the peer-side SwiftUI `Canvas` overlay, so ink looks identical on every screen.
private final class InkOverlayView: NSView {
    var strokes: [DrawOp] = []

    override var isFlipped: Bool { true } // top-left origin, matching NormalizedPoint semantics

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()
        let aspect = Double(bounds.width / max(bounds.height, 1))
        for op in strokes {
            guard op.points.count > 1 else { continue }
            let path = NSBezierPath()
            path.lineWidth = CGFloat(op.width)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let pts = op.points.map {
                VideoFitMath.viewPoint(fromNormalized: $0, videoAspect: aspect, viewSize: bounds.size)
            }
            path.move(to: pts[0])
            for p in pts.dropFirst() { path.line(to: p) }
            NSColor(calibratedRed: op.color.r, green: op.color.g, blue: op.color.b, alpha: op.color.a).setStroke()
            path.stroke()
        }
    }
}
