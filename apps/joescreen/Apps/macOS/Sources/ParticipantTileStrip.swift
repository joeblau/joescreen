import SwiftUI
import AppKit
import JoeScreenKit
import JoeScreenLiveKit
import LiveKit

/// The inspector's vertical face list (M10): the self tile first (mirrored), then one tile per remote
/// participant, ordered by the pure `TileSubscriptionPlanner` (name-then-UUID, stable). Each tile
/// shows live camera video when its camera can be decoded, or an avatar otherwise. Off-screen tiles
/// detach through `LazyVStack`, letting adaptive-stream stop forwarding those cameras (R24/R32).
struct ParticipantFaceColumn: View {
    @Environment(AppModel.self) private var model
    var selectedParticipantID: ParticipantID?

    private var tiles: [TileSubscriptionPlanner.Tile] {
        guard let selectedParticipantID,
              let selected = model.plannedTiles.first(where: { $0.participant == selectedParticipantID }) else {
            return model.plannedTiles
        }
        return [selected] + model.plannedTiles.filter { $0.participant != selectedParticipantID }
    }

    var body: some View {
        if tiles.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "person.crop.rectangle.stack")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("Waiting for participants…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 12) {
                    ForEach(tiles, id: \.participant) { tile in
                        ParticipantFaceTile(tile: tile, isSelected: tile.participant == selectedParticipantID)
                    }
                }
                .padding(10)
            }
        }
    }
}

/// One aspect-true face tile that fills the inspector's width.
private struct ParticipantFaceTile: View {
    @Environment(AppModel.self) private var model
    let tile: TileSubscriptionPlanner.Tile
    let isSelected: Bool

    private var media: ParticipantMediaState? { model.mediaState(for: tile.participant) }
    private var color: Color { model.color(for: tile.participant) }
    private var name: String { model.displayLabel(for: tile.participant) }
    private var micLive: Bool { tile.isSelf ? model.micEnabled : (media?.micLive ?? false) }
    private var isSpeaking: Bool { media?.isSpeaking ?? false }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black)
                content
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                // Speaking ring (green) over the color ring.
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSpeaking ? Color.green : (isSelected ? Color.accentColor : color),
                                  lineWidth: isSelected ? 4 : 3)
                // Mic-off badge, bottom-left.
                if !micLive {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "mic.slash.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(Color.red, in: Circle())
                            Spacer()
                        }
                    }
                    .padding(5)
                }
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            Text(tile.isSelf ? "\(name) (you)" : name)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onTapGesture {
            // Tapping a remote tile raises all that owner's shared windows.
            if !tile.isSelf { model.focusSharesOf(owner: tile.participant) }
        }
    }

    @ViewBuilder private var content: some View {
        if tile.isSelf {
            // Self: mirrored local camera preview when the camera is on, else avatar.
            if let track = model.localCameraTrack {
                VideoSurface(track: track, mirrorMode: .mirror)
            } else {
                AvatarView(name: name, color: color)
            }
        } else if tile.decoded, media?.cameraOn == true, let track = model.cameraTrack(for: tile.participant) {
            // Remote: live camera only when decodable (budget) AND camera-on (not a muted frozen frame).
            VideoSurface(track: track)
        } else {
            AvatarView(name: name, color: color)
        }
    }
}

/// Owns the one session-scoped floating active-speaker panel. It uses a non-activating NSPanel so
/// showing or updating PiP never steals keyboard focus from the app the user is collaborating in.
@MainActor
final class ActiveSpeakerPictureInPictureManager: NSObject, NSWindowDelegate {
    weak var model: AppModel?
    private var panel: NSPanel?

    func show() {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        guard let model else { return }

        let size = NSSize(width: 640, height: 400)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.title = "Active Speaker"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentAspectRatio = NSSize(width: 16, height: 10)
        panel.minSize = NSSize(width: 240, height: 150)
        panel.contentViewController = NSHostingController(
            rootView: ActiveSpeakerPictureInPictureView().environment(model))
        panel.delegate = self

        let visible = (NSScreen.main?.visibleFrame)
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - panel.frame.width - 24,
            y: visible.maxY - panel.frame.height - 24))

        self.panel = panel
        panel.orderFrontRegardless()
    }

    func close() {
        guard let panel else { return }
        panel.delegate = nil
        panel.close()
        self.panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        model?.activeSpeakerPictureInPictureDidClose()
    }
}

/// Live PiP content. The observable AppModel swaps this renderer to the newest loudest speaker;
/// the `.id` forces LiveKit's renderer attachment to follow the track change immediately.
private struct ActiveSpeakerPictureInPictureView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            if let participantID = model.pictureInPictureParticipantID {
                speakerContent(participantID)
                    .id(participantID)
                speakerChrome(participantID)
            } else {
                ContentUnavailableView(
                    "Waiting for a Speaker",
                    systemImage: "person.wave.2",
                    description: Text("The active participant will appear here."))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 240, minHeight: 150)
        .clipped()
    }

    @ViewBuilder
    private func speakerContent(_ participantID: ParticipantID) -> some View {
        if participantID == model.localParticipantID, let track = model.localCameraTrack {
            VideoSurface(track: track, mirrorMode: .mirror)
                .ignoresSafeArea()
        } else if model.mediaState(for: participantID)?.cameraOn == true,
                  let track = model.cameraTrack(for: participantID) {
            VideoSurface(track: track)
                .ignoresSafeArea()
        } else {
            ZStack {
                Color.black
                AvatarView(
                    name: model.displayLabel(for: participantID),
                    color: model.color(for: participantID),
                    size: 88)
            }
        }
    }

    private func speakerChrome(_ participantID: ParticipantID) -> some View {
        let media = model.mediaState(for: participantID)
        let micLive = participantID == model.localParticipantID ? model.micLive : (media?.micLive ?? false)
        return HStack(spacing: 7) {
            Circle()
                .fill(media?.isSpeaking == true ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(model.displayLabel(for: participantID))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
            if !micLive {
                Image(systemName: "mic.slash.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom))
    }
}

/// The fallback tile face: a participant-color circle with up-to-two-letter initials.
private struct AvatarView: View {
    let name: String
    let color: Color
    var size: CGFloat = 52

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        let joined = letters.joined().uppercased()
        return joined.isEmpty ? "?" : String(joined.prefix(2))
    }

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.85)).frame(width: size, height: size)
            Text(initials)
                .font(size >= 80 ? .largeTitle.weight(.semibold) : .headline.weight(.semibold))
                .foregroundStyle(.white)
        }
    }
}
