import SwiftUI
import AppKit
import Observation
import JoeScreenKit
import JoeScreenLiveKit
import JoeScreenCaptureMac
import JoeScreenInputMac
import ScreenCaptureKit
import AVFoundation
import LiveKit

/// The single selection domain for the session navigator. A participant selection filters the
/// center share grid to that owner; the fixed destinations show all shares or the room notes.
public enum SidebarSelection: Hashable {
    case screenShares
    case notes
    case participant(ParticipantID)

    fileprivate var persistenceKey: String {
        switch self {
        case .screenShares: return "screen-shares"
        case .notes: return "notes"
        case .participant(let id): return "participant:\(id.uuidString)"
        }
    }

    fileprivate init?(persistenceKey: String) {
        if persistenceKey == "screen-shares" {
            self = .screenShares
        } else if persistenceKey == "notes" {
            self = .notes
        } else if persistenceKey.hasPrefix("participant:"),
                  let id = ParticipantID(uuidString: String(persistenceKey.dropFirst("participant:".count))) {
            self = .participant(id)
        } else {
            return nil
        }
    }
}

/// The central @MainActor observable app state and orchestrator for the macOS client.
///
/// It owns the connection lifecycle (Direct Session Mode → LiveKit media plane), the roster, the
/// mirrored `RoomModel`, the remote video tracks (rendered as native NSWindows), and the local
/// capture/publish flow. This is where M2 (transport), M3 (capture), and M4 (the call UI + state
/// sync) come together into a working call.
@MainActor
@Observable
public final class AppModel {

    public enum Phase: Equatable {
        case idle
        case connecting
        case inCall
        case failed(String)
    }

    // MARK: - Observable state

    public private(set) var phase: Phase = .idle
    public private(set) var joinParameters: DirectJoinParameters?
    public private(set) var localParticipantID: ParticipantID?
    /// The mirrored room state. On the sharer this is the authoritative copy it broadcasts; on a
    /// joiner it's the union-merge of every snapshot applied from the `state` channel.
    public private(set) var room = RoomModel()
    public private(set) var participants: Set<ParticipantID> = []
    /// Stable, collision-free color slots retained for the duration of one call. Departed slots are
    /// not reused, so a reconnect never changes somebody's established visual identity.
    @ObservationIgnored private var participantColorSlots: [ParticipantID: Int] = [:]
    public private(set) var mediaState: MediaConnectionState = .disconnected
    public var showJoinSheet: Bool = true

    // MARK: - Session navigation + inspector restoration

    @ObservationIgnored @AppStorage("JoeScreen.session.sidebarSelection")
    private var persistedSidebarSelection = "screen-shares"
    @ObservationIgnored @AppStorage("JoeScreen.session.screenSharesExpanded")
    private var persistedScreenSharesSectionExpanded = true
    @ObservationIgnored @AppStorage("JoeScreen.session.notesExpanded")
    private var persistedNotesSectionExpanded = true
    @ObservationIgnored @AppStorage("JoeScreen.session.participantsExpanded")
    private var persistedParticipantsSectionExpanded = true
    @ObservationIgnored @AppStorage("JoeScreen.session.inspectorWidth")
    private var persistedInspectorWidth = 260.0
    @ObservationIgnored @AppStorage("JoeScreen.session.inspectorPresented")
    private var persistedInspectorPresented = true

    /// The only selection state used by the navigator and detail area.
    public var sidebarSelection: SidebarSelection = .screenShares {
        didSet {
            guard sidebarSelection != oldValue else { return }
            persistedSidebarSelection = sidebarSelection.persistenceKey
        }
    }
    /// Collapsible native List sections, mirrored into observable state and persisted by AppStorage.
    public var screenSharesSectionExpanded = true {
        didSet { persistedScreenSharesSectionExpanded = screenSharesSectionExpanded }
    }
    public var notesSectionExpanded = true {
        didSet { persistedNotesSectionExpanded = notesSectionExpanded }
    }
    public var participantsSectionExpanded = true {
        didSet { persistedParticipantsSectionExpanded = participantsSectionExpanded }
    }
    /// Actual inspector presentation. Framework-driven changes update this value without changing
    /// the user's saved preference; only explicit toolbar actions persist visibility.
    public private(set) var inspectorIsPresented = true
    public private(set) var inspectorWidth = 260.0
    @ObservationIgnored private var inspectorWidthPersistenceTask: Task<Void, Never>?

    // MARK: - Active-speaker picture in picture

    /// The loudest participant currently reported as speaking. The audio activity pump updates this
    /// at 10 Hz; when the room goes quiet the last speaker remains selected until somebody else talks.
    public private(set) var activeSpeakerParticipantID: ParticipantID?
    /// Session-scoped presentation state for the floating active-speaker panel.
    public private(set) var isActiveSpeakerPictureInPicturePresented = false

    /// PiP has a useful initial subject even before LiveKit reports its first speaking transition.
    public var pictureInPictureParticipantID: ParticipantID? {
        if let activeSpeakerParticipantID, participants.contains(activeSpeakerParticipantID) {
            return activeSpeakerParticipantID
        }
        if let localParticipantID { return localParticipantID }
        return participants.sorted { $0.uuidString < $1.uuidString }.first
    }

    public var selectedParticipantID: ParticipantID? {
        guard case .participant(let id) = sidebarSelection else { return nil }
        return id
    }

    /// Remote video tracks we're rendering, keyed by JoeScreen windowID (parsed from the track name).
    /// The RemoteWindowManager opens/closes native NSWindows to match this set.
    public private(set) var remoteWindows: [WindowID: RemoteVideoWindow] = [:]

    /// Per-participant live media presence (name/speaking/mic/camera) for the tile strip (M10),
    /// pushed reactively from the transport. cameraOn distinguishes "show video" from "show avatar"
    /// (a muted camera stays subscribed → cameraTracks still holds it, but cameraOn is false).
    public private(set) var participantMedia: [ParticipantID: ParticipantMediaState] = [:]

    /// Remote participant CAMERA tracks (M10), keyed by owner. Distinct from window shares — these
    /// render as tiles in the participant strip, not native windows. A muted camera stays subscribed
    /// (LiveKit mutes rather than unpublishes), so presence here means "renderable camera track"; the
    /// cameraOn flag in ParticipantMediaState governs whether to show video vs an avatar.
    public private(set) var cameraTracks: [ParticipantID: JoeScreenLiveKit.RemoteVideoTrackRef] = [:]
    /// The SID that delivered each owner's camera track, so a trackGone for that SID clears it.
    private var cameraTrackSIDs: [ParticipantID: String] = [:]

    /// Per-window lifecycle state machines (M9). AppModel feeds events (subscribe/gone/close/
    /// reopen/miniaturize/occlude/reconnecting/snapshot-removal) and EXECUTES the returned effects.
    /// All the dead-window/desync correctness lives in the pure `RemoteWindowLifecycle` reducer.
    private var lifecycles: [WindowID: RemoteWindowLifecycle] = [:]
    /// Grace timers for windows parked in `.stale` during a reconnect (fire `graceExpired`).
    private var graceTimers: [WindowID: Task<Void, Never>] = [:]
    /// The reconnect grace window before a stale (frozen-frame) viewer is torn down (SFU link blip).
    private static let reconnectGraceSeconds: UInt64 = 10
    /// The SHORT grace for a bare trackEnded while connected — long enough to catch a codec-
    /// renegotiation resubscribe (~1s, M11) or confirm a real sharer crash, short enough that a real
    /// crash tears the window down promptly (≤2s target).
    private static let renegotiationGraceSeconds: UInt64 = 2

    // MARK: - Shared transcript (live speech-to-text + recording notes)

    /// The merged shared transcript: every participant's segments (deduped by segmentID, final over
    /// partial) plus the recording-note boundary events, all applied idempotently. Pure projection
    /// source for the transcript pane (D19).
    public private(set) var transcript = TranscriptModel()
    /// Local mic → shared transcript (Apple Speech on its own audio engine). Observable; the UI
    /// reads `state` for the soft-failure reason.
    public let transcriptionService = TranscriptionService()
    /// Remote speakers → local transcript (one recognition stream per remote audio track), so one
    /// person enabling Transcribe captions the whole room on their own Mac. Local-only segments.
    private let remoteTranscription = RemoteTranscriptionManager()
    /// The user's transcription toggle (drives BOTH pipelines). Kept separate from the service's
    /// state so the button reflects intent even when one pipeline fails soft (e.g. mic denied but
    /// remote captions still running).
    public private(set) var transcriptionEnabled = false
    /// Last time each remote speaker self-published a transcript segment. While recent (see
    /// `selfPublishSuppressionWindow`), our local recognition of that speaker is suppressed — their
    /// own mic's segments (better audio, their consent) win, and nothing shows up twice.
    private var lastSelfPublishedSegmentAt: [ParticipantID: TimeInterval] = [:]
    private static let selfPublishSuppressionWindow: TimeInterval = 15
    private var transcriptChannel: (any WireDataChannel)?

    // MARK: - Local media controls (mic + webcam)

    /// Whether the local microphone is currently publishing. Drives the mic toggle in the control bar.
    public private(set) var micEnabled: Bool = false
    /// The EFFECTIVE mic state — what the connected room actually hears: the user's intent
    /// (`micEnabled`) minus any gate-applied hold (`gateMuted`). The toggle displays and acts on
    /// this so its direction always matches the audible state of the connected person, never just
    /// the last manual intent.
    public var micLive: Bool { micEnabled && !gateMuted }
    /// Whether the local webcam is currently publishing. Drives the camera toggle in the control bar.
    public private(set) var cameraEnabled: Bool = false
    /// Whether a camera enable/disable/switch is in flight. Opening a capture device, producing the
    /// first frame, and publishing can take seconds (external cameras especially) — the control bar
    /// shows a spinner instead of the camera icon while this is true.
    public private(set) var cameraBusy: Bool = false
    /// The selectable audio-input devices for the mic dropdown (refreshed on join / when opened).
    public private(set) var audioInputs: [MediaInputDevice] = []
    /// The selectable webcam devices for the camera dropdown (refreshed on join / after camera TCC).
    public private(set) var videoInputs: [MediaInputDevice] = []
    /// The chosen audio-input device id (nil = system default). Shows a checkmark in the mic dropdown.
    public private(set) var selectedAudioInputID: String?
    /// The chosen webcam device id (nil = system default). Shows a checkmark in the camera dropdown.
    public private(set) var selectedVideoInputID: String?
    /// The local webcam track for the self-preview tile; non-nil exactly while the camera is on.
    public private(set) var localCameraTrack: VideoTrack?
    /// Local published screen-share tracks by windowID, for the sharer's OWN thumbnail self-preview
    /// (you don't subscribe to your own publications, so there's no remote track). Populated when a
    /// share goes live, cleared on unshare. Observable so the tile re-renders when it becomes available.
    public private(set) var localWindowTracks: [WindowID: VideoTrack] = [:]

    // MARK: - Co-located audio gate (D21)

    /// True while the co-located-speaker gate is holding the local mic muted (a marked co-located
    /// peer is the dominant speaker). Drives the subtle control-bar indicator.
    public private(set) var gateMuted: Bool = false
    /// The user-marked set of co-located participants (people in the same physical room, whose
    /// voice reaches this Mac acoustically). Persisted in UserDefaults across launches.
    public private(set) var coLocatedParticipants: Set<ParticipantID> = []
    /// The pure dominance-gate state machine (JoeScreenKit).
    private var audioGate = CoLocatedAudioGate()
    /// True when the CURRENT mic mute was applied by the gate (not the user). The gate may unmute
    /// only what it muted itself — it must never override a manual mute.
    private var gateAppliedMicMute = false
    private static let coLocatedDefaultsKey = "JoeScreen.coLocatedParticipants"
    /// Token for the passive global ⌘⇧M key monitor. Retained so the monitor (and the ability to
    /// remove it) lives as long as the model.
    private var globalMicHotkeyMonitor: Any?

    /// Whether to join the next call MUTED (backlog #2). Persisted; default false (join unmuted).
    public var joinMuted: Bool {
        get { UserDefaults.standard.bool(forKey: "JoeScreen.joinMuted") }
        set { UserDefaults.standard.set(newValue, forKey: "JoeScreen.joinMuted") }
    }
    /// Session-scoped `--join-muted` launch flag (the two-instance-one-Mac dev loop: a second
    /// instance with a live mic turns the shared speaker/mic pair into a feedback loop, because
    /// each process's AEC only knows its OWN render stream). NOT persisted — UserDefaults are
    /// shared by bundle id, so persisting would mute both instances.
    public var launchMutedJoin = false

    /// The live connected-participant set as reported by the transport (local + all remotes). The
    /// authoritative membership source; the displayed `participants` roster is recomputed from this
    /// unioned with current share owners. Kept separate so disconnects actually remove people.
    private var transportParticipants: Set<ParticipantID> = []

    /// Surfaces this instance is locally sharing (window OR display capture services), keyed by
    /// windowID. Typed as the `ShareCaptureService` existential so window + display share uniformly.
    private var localCaptures: [WindowID: any ShareCaptureService] = [:]
    /// The kind (window/display) of each local share, so unshare updates the context correctly.
    private var localShareKinds: [WindowID: ShareKind] = [:]
    /// Where each local share lives on screen (F9 sharer-side ink overlay targets).
    private var localShareScreenTargets: [WindowID: InkTarget] = [:]
    /// The structural share context this host publishes (D5). Updated to include a PENDING share
    /// BEFORE publishing it, so the new track gets the right codec (the ordering fix, latent #3).
    private var shareContext = ShareContext()
    /// Admitted target bitrate (bps) per local share, for uplink admission (M11).
    private var localShareBitrates: [WindowID: Double] = [:]

    /// Admission controller (M11 — revives dead code #4). Config reconciliation: the TYPE default for
    /// maxEncodeSessions stays 1 (conservative base-chip) pending the Phase-0(f) hardware
    /// measurement; the call-site override to 3 reflects that a base Apple-Silicon Mac sustains a few
    /// low-latency encode sessions (window + display mixes). uplink is ASSUMED 20 Mbps until measured.
    private let admission = AdmissionController(config: .init(maxEncodeSessions: 3))
    /// ASSUMED measured uplink (bps) until Phase-0(f) — labeled so it's obvious it's a placeholder.
    private static let assumedUplinkBps: Double = 20_000_000
    /// Whether a share was refused by admission (drives a visible alert in the UI).
    public private(set) var shareRefusedReason: String?

    // MARK: - Remote control (F4) — coordination-plane display state only (D12: authorization is
    // owner-side against trusted local state, NOT these flags).

    /// The participant currently driving one of MY shared windows (drives the "X is driving" badge).
    /// nil when nobody is remote-controlling. Display-only.
    public private(set) var activeDriver: ParticipantID?
    /// A pending control request awaiting the owner's consent (drives a consent prompt). Display-only.
    public private(set) var pendingControlRequest: ControlRequest?
    /// The R8 secure-input banner state (shown when secure input blocks injection while driving).
    public private(set) var secureInputBanner: SecureInputBanner = .none
    private var inputPump: InputPump?

    /// Cross-user clipboard sync (F6, backlog #3). SESSION-SCOPED, default OFF, NEVER persisted
    /// (DECISIONS §5.5 — security posture wins). Drives the control-bar toggle.
    public private(set) var clipboardSyncEnabled = false

    /// Replicated annotation ink (F9, backlog #9). Observed by the DrawOverlay; mutated by the pump.
    let drawState = DrawState()
    private var drawPump: DrawPump?

    /// Hover "Share" tab (F/backlog #10). Session-scoped, default OFF; R4-safe (picker) until the spike.
    public private(set) var hoverShareEnabled = false
    @ObservationIgnored private var hoverShare: HoverShareController!
    /// The local author's monotonic draw sequence — assigned HERE (MainActor) so the optimistic
    /// local apply and the transmitted op carry the SAME seq (no duplicate on the inbound echo).
    private var drawSequencer = DrawAuthorSequencer()

    // MARK: - Collaborators

    private let transport = LiveKitTransport()
    private let windowManager = RemoteWindowManager()
    private let pictureInPictureManager = ActiveSpeakerPictureInPictureManager()
    private let borderOverlay = ShareBorderOverlay()
    private let inkOverlay = RemoteInkOverlayManager()
    private var stateChannel: (any WireDataChannel)?
    private var cursorPump: CursorPump?
    private var clipboardPump: ClipboardPump?

    private var launchJoin: DirectJoinParameters?
    private var launchJoinFired = false
    /// Optional CGWindowID to auto-share after joining (the --share-window-id automation path).
    private var autoShareWindowID: UInt32?
    /// Optional CGDirectDisplayID to auto-share after joining (--share-display-id / --share-main-display).
    private var autoShareDisplayID: CGDirectDisplayID?
    private var pumps: [Task<Void, Never>] = []

    public init(launchJoin: DirectJoinParameters? = nil, autoShareWindowID: UInt32? = nil,
                autoShareDisplayID: CGDirectDisplayID? = nil) {
        sidebarSelection = SidebarSelection(persistenceKey: persistedSidebarSelection) ?? .screenShares
        screenSharesSectionExpanded = persistedScreenSharesSectionExpanded
        notesSectionExpanded = persistedNotesSectionExpanded
        participantsSectionExpanded = persistedParticipantsSectionExpanded
        inspectorWidth = min(max(persistedInspectorWidth, 220), 380)
        inspectorIsPresented = persistedInspectorPresented
        self.launchJoin = launchJoin
        self.autoShareWindowID = autoShareWindowID
        self.autoShareDisplayID = autoShareDisplayID
        if launchJoin != nil { self.showJoinSheet = false }
        windowManager.model = self
        pictureInPictureManager.model = self
        inkOverlay.providers = { [weak self] in
            guard let self else { return (DrawModel(), [:]) }
            return (self.drawState.model, self.localShareScreenTargets)
        }
        hoverShare = HoverShareController(model: self)
        installGlobalMicHotkey()
        coLocatedParticipants = Set(
            (UserDefaults.standard.stringArray(forKey: Self.coLocatedDefaultsKey) ?? [])
                .compactMap(ParticipantID.init(uuidString:)))
    }

    /// Explicit user action: toggle and persist inspector visibility. One global preference — the
    /// inspector does not follow the navigator selection.
    public func toggleInspector() {
        setInspectorPresented(!inspectorIsPresented, persistPreference: true)
    }

    /// SwiftUI may temporarily hide the inspector while reconciling columns/window size. Reflect the
    /// actual presentation without overwriting the user's saved preference.
    public func handleSystemInspectorPresentationChange(_ isPresented: Bool) {
        setInspectorPresented(isPresented, persistPreference: false)
    }

    /// Explicit toolbar action for the session-scoped active-speaker PiP panel.
    public func setActiveSpeakerPictureInPicturePresented(_ isPresented: Bool) {
        guard isPresented != isActiveSpeakerPictureInPicturePresented else { return }
        isActiveSpeakerPictureInPicturePresented = isPresented
        if isPresented {
            pictureInPictureManager.show()
        } else {
            pictureInPictureManager.close()
        }
    }

    /// Called by the panel delegate when the user closes PiP with its native close button.
    func activeSpeakerPictureInPictureDidClose() {
        isActiveSpeakerPictureInPicturePresented = false
    }

    /// Persist a user-resized inspector width without feeding it back into the live column. The
    /// fixed `inspectorWidth` remains the animation target until the next presentation, so geometry
    /// observation cannot move the target while AppKit's native transition is in flight.
    public func recordInspectorWidth(_ width: Double) {
        inspectorWidthPersistenceTask?.cancel()
        inspectorWidthPersistenceTask = nil

        guard inspectorIsPresented, width.isFinite, width >= 200 else { return }
        let clamped = min(max(width, 220), 380)
        guard abs(clamped - persistedInspectorWidth) >= 1 else { return }

        inspectorWidthPersistenceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }

            guard let self else { return }
            defer { self.inspectorWidthPersistenceTask = nil }
            guard self.inspectorIsPresented else { return }
            guard abs(clamped - self.persistedInspectorWidth) >= 1 else { return }
            self.persistedInspectorWidth = clamped
        }
    }

    private func setInspectorPresented(_ isPresented: Bool, persistPreference: Bool) {
        if !isPresented {
            inspectorWidthPersistenceTask?.cancel()
            inspectorWidthPersistenceTask = nil
        }
        if persistPreference {
            persistedInspectorPresented = isPresented
        }
        guard inspectorIsPresented != isPresented else { return }
        if isPresented {
            // Updating the preferred width while the inspector is hidden cannot interfere with
            // its transition; SwiftUI may still restore a newer native divider position.
            inspectorWidth = min(max(persistedInspectorWidth, 220), 380)
        }
        inspectorIsPresented = isPresented
    }

    /// Install a passive global ⌘⇧M monitor so the mic can be toggled while the app isn't focused.
    /// The monitor only observes the event (the focused app still receives it). macOS may withhold
    /// global key events without Input Monitoring permission, so the in-app Call-menu shortcut
    /// (same keystroke) remains the guaranteed path.
    private func installGlobalMicHotkey() {
        globalMicHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.command), event.modifierFlags.contains(.shift),
                  event.charactersIgnoringModifiers?.lowercased() == "m" else { return }
            Task { @MainActor in
                guard let self, self.phase == .inCall else { return }
                self.toggleMic()
            }
        }
    }

    // MARK: - Join entry points

    public func startLaunchJoinIfNeeded() {
        guard !launchJoinFired, let params = launchJoin else { return }
        launchJoinFired = true
        requestJoin(params)
    }

    public func requestJoin(_ params: DirectJoinParameters) {
        // Clear any per-session UI/state orphaned from a PRIOR session before reconnecting. "Try Again"
        // (after a .failed) and re-joins call this directly WITHOUT going through teardown(), so a
        // display share's red border overlay (and share bookkeeping) from the old session would survive
        // into the new one — the "red outline still on screen but no longer sharing" bug. teardown()
        // hides it, but the retry path skips teardown, so reset it here too.
        resetLocalShareState()
        joinParameters = params
        localParticipantID = params.participantID
        showJoinSheet = false
        phase = .connecting
        recordRecent(params) // menu-bar "Recent" list (backlog #5)
        Task { await connect(params) }
    }

    /// Tear down the sharer's own local-share affordances + bookkeeping (border overlay, chip, capture
    /// registries). Safe to call when not sharing (all no-ops). Used by both a fresh join (clear a
    /// prior session's orphans) and teardown. Does NOT touch the transport/room — callers own that.
    private func resetLocalShareState() {
        borderOverlay.hide()
        inkOverlay.hideAll()
        localShareScreenTargets.removeAll()
        isSharingDisplay = false
        for (_, capture) in localCaptures { Task { await capture.stop() } }
        localCaptures.removeAll()
        localWindowTracks.removeAll()
        localShareKinds.removeAll()
        localShareBitrates.removeAll()
        shareContext = ShareContext()
    }

    // MARK: - Recents (backlog #5)

    private static let recentsKey = "JoeScreen.recents"

    /// The persisted recent-sessions list (most-recent-first). Drives the menu-bar "Recent" submenu.
    public private(set) var recents: RecentsStore = AppModel.loadRecents()

    private static func loadRecents() -> RecentsStore {
        guard let data = UserDefaults.standard.data(forKey: recentsKey),
              let store = try? JSONDecoder().decode(RecentsStore.self, from: data) else { return RecentsStore() }
        return store
    }

    private func recordRecent(_ params: DirectJoinParameters) {
        recents.record(RecentsStore.Entry(
            serverURL: params.serverURL.absoluteString, room: params.room, displayName: params.displayName))
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: Self.recentsKey)
        }
    }

    /// Re-join a recent session (menu-bar). Mints a fresh identity per the identity rule.
    public func joinRecent(_ entry: RecentsStore.Entry) {
        guard let url = URL(string: entry.serverURL) else { return }
        requestJoin(DirectJoinParameters(serverURL: url, room: entry.room, displayName: entry.displayName))
    }

    /// Remove every recent room from memory and persisted defaults.
    public func clearRecentRooms() {
        recents.clear()
        UserDefaults.standard.removeObject(forKey: Self.recentsKey)
    }

    /// A shareable `joescreen://` invite link for the current (or a given) session, for the menu-bar
    /// "Copy invite link". Identity omitted (fresh per joiner — the identity rule).
    public var inviteURL: URL? { joinParameters?.shareableURL() }

    public func leave() {
        Task { await teardown() }
    }

    // MARK: - Connect

    private func connect(_ params: DirectJoinParameters) async {
        let identity = params.identity
        // Display name (M10) → JWT `name` claim → participant.name for everyone incl. late joiners.
        let displayName = params.displayName
        // Resolve (token, SFU URL). DEBUG mints a local dev-key token and dials the URL as-is (dev
        // SFU). RELEASE fetches from the token server, which returns the AUTHORITATIVE SFU URL to dial
        // (token server + SFU may be different hosts). `serverURL` here is the token-server base in
        // Release, the SFU URL in DEBUG — see DirectJoinParameters.
        let token: String
        let sfuURL: URL
        #if DEBUG
        token = DevTokenMinter.mint(identity: identity, room: params.room, name: displayName)
        sfuURL = params.serverURL
        #else
        do {
            let creds = try await TokenClient.fetch(server: params.serverURL, room: params.room,
                                                    identity: identity, name: displayName)
            token = creds.token
            sfuURL = creds.sfuURL
        } catch { fail("token: \(error)"); return }
        #endif

        // Install the unified remote-track hook BEFORE connecting so we don't miss early
        // subscriptions. The descriptor carries the resolved ownerID (correct owner attribution) and
        // sourceKind; TrackClassifier routes it to a window share vs a camera tile vs ignore.
        await transport.setOnRemoteTrack { [weak self] descriptor, track in
            let classification = TrackClassifier.classify(
                name: descriptor.trackName, source: descriptor.sourceKind.trackSource)
            let owner = descriptor.ownerID
            let sid = descriptor.trackSID
            Task { @MainActor in
                guard let self else { return }
                switch classification {
                case .windowShare(let windowID):
                    self.addRemoteWindow(windowID: windowID, ownerHint: owner, track: track)
                case .camera:
                    if let owner { self.addCameraTrack(owner: owner, sid: sid, track: track) }
                case .ignore:
                    break
                }
            }
        }
        // Install the track-gone hook: a sharer/camera that stops/crashes/disconnects fires this, and
        // we close+purge the viewer window (frozen-ghost fix) or drop the camera tile.
        await transport.setOnTrackGone { [weak self] gone in
            let classification = TrackClassifier.classify(
                name: gone.trackName, source: gone.sourceKind.trackSource)
            let owner = gone.ownerID
            let sid = gone.trackSID
            Task { @MainActor in
                guard let self else { return }
                switch classification {
                case .windowShare(let windowID):
                    self.handleRemoteTrackGone(windowID: windowID)
                case .camera:
                    if let owner { self.removeCameraTrack(owner: owner, sid: sid) }
                case .ignore:
                    break
                }
            }
        }
        // Participant media state (M10): name/speaking/mic/camera pushed reactively for the tile strip.
        await transport.setOnParticipantMediaChanged { [weak self] states in
            Task { @MainActor in self?.applyParticipantMedia(states) }
        }

        // Install the participant-roster hook BEFORE connecting so early joiners aren't missed. This
        // is what makes EVERYONE connected appear in the roster — not just those who've shared a
        // window (the old snapshot-only derivation left non-sharing peers, and often yourself, absent).
        await transport.setOnParticipantsChanged { [weak self] ids in
            Task { @MainActor in self?.applyParticipantSet(ids) }
        }

        // Bridge connection state + participants.
        startConnectionPump()
        startParticipantPump()

        do {
            AppLog.info("connecting to \(params.serverURL.absoluteString) room=\(params.room) identity=\(identity)")
            try await transport.connect(.init(serverURL: sfuURL, authToken: token))
            AppLog.info("connected; opening channels")
            try await transport.openAllDataChannels()
            let state = try await transport.openDataChannel(.state)
            self.stateChannel = state
            startStatePump(state)
            // Shared transcript channel (D19): merged live speech-to-text + recording notes.
            let transcriptCh = try await transport.openDataChannel(.transcript)
            self.transcriptChannel = transcriptCh
            startTranscriptPump(transcriptCh)
            // Voice isolation (VPIO) preference: applied BEFORE the mic first enables so the
            // capture engine starts in the persisted state instead of restarting after.
            await transport.setVoiceIsolation(enabled: voiceIsolationEnabled)
            // Enable the mic on join (M5) UNLESS the user opted to join muted (backlog #2) or the
            // session launched with --join-muted (dev loop). Joining muted still publishes the
            // track (LiveKit mutes rather than unpublishes), so unmuting later is instant and
            // peers see the correct mic-off badge meanwhile.
            try? await transport.setMicrophone(enabled: !(joinMuted || launchMutedJoin))
            micEnabled = await transport.isMicrophoneEnabled()
            startAudioGatePump()
            // Start the cursor pump (M6).
            let cursor = try await transport.openDataChannel(.cursor)
            let pump = CursorPump(channel: cursor, localID: localParticipantID)
            self.cursorPump = pump
            windowManager.cursorPump = pump
            startCursorInPump(pump)
            // Start the input pump (F4) on the reliable/ordered input channel. Owner-side injection is
            // gated behind the kTCCServicePostEvent grant (human step); the pump receives + surfaces
            // control requests now, and injects once the grant + strategy spike land.
            let input = try await transport.openDataChannel(.input)
            startInputPump(input)
            // Prepare the clipboard pump (F6) — created but DISABLED (session-scoped, default OFF).
            let clipboard = try await transport.openDataChannel(.clipboard)
            clipboardPump = ClipboardPump(channel: clipboard, localID: localParticipantID)
            // Draw pump (F9): apply inbound ink to the shared DrawState.
            let drawCh = try await transport.openDataChannel(.draw)
            let drawPump = DrawPump(channel: drawCh, localID: localParticipantID)
            self.drawPump = drawPump
            startDrawInPump(drawPump)
            phase = .inCall
            // Seed the local participant into the roster immediately.
            if let me = localParticipantID { participants.insert(me) }
            // Pre-fill the input-device pickers OFF the join path: `CameraCapturer.captureDevices()`
            // can block / trigger the camera-TCC prompt, so it must never sit inline in connect (it
            // would stall the whole session — incl. remote-track rendering). The menus also refresh
            // on open, so an empty list here is harmless.
            Task { [weak self] in await self?.refreshInputDevices() }
            // Automation: auto-share a window if --share-window-id was passed.
            if let cgWindowID = autoShareWindowID {
                autoShareWindowID = nil
                shareWindow(cgWindowID: cgWindowID)
            }
            // Automation: auto-share a display if --share-display-id / --share-main-display was passed.
            if let displayID = autoShareDisplayID {
                autoShareDisplayID = nil
                shareDisplay(displayID: displayID)
            }
        } catch {
            fail(String(describing: error))
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        showJoinSheet = false
    }

    private func teardown() async {
        for t in pumps { t.cancel() }
        pumps.removeAll()
        for (id, capture) in localCaptures {
            await capture.stop()
            await transport.unpublishVideoTrack(for: id)
        }
        localCaptures.removeAll()
        localWindowTracks.removeAll()
        localShareKinds.removeAll()
        localShareBitrates.removeAll()
        shareContext = ShareContext()
        shareRefusedReason = nil
        borderOverlay.hide()
        isSharingDisplay = false
        await transport.disconnect()
        pictureInPictureManager.close()
        isActiveSpeakerPictureInPicturePresented = false
        activeSpeakerParticipantID = nil
        windowManager.closeAll()
        remoteWindows.removeAll()
        cameraTracks.removeAll()
        cameraTrackSIDs.removeAll()
        participantMedia = [:]
        displayNames = [:]
        for t in graceTimers.values { t.cancel() }
        graceTimers.removeAll()
        lifecycles.removeAll()
        micEnabled = false
        cameraEnabled = false
        cameraBusy = false
        localCameraTrack = nil
        audioGate.release()
        gateAppliedMicMute = false
        gateMuted = false
        stopTranscription()
        transcript = TranscriptModel()
        transcriptChannel = nil
        lastSelfPublishedSegmentAt = [:]
        audioInputs = []
        videoInputs = []
        selectedAudioInputID = nil
        selectedVideoInputID = nil
        phase = .idle
        participants = []
        transportParticipants = []
        room = RoomModel()
        localParticipantID = nil
        participantColorSlots.removeAll()
        mediaState = .disconnected
        stateChannel = nil
        cursorPump = nil
        inputPump = nil
        clipboardPump?.stop()
        clipboardPump = nil
        clipboardSyncEnabled = false
        drawPump = nil
        drawSequencer = DrawAuthorSequencer()
        drawState.reset()
        hoverShare.setEnabled(false)
        hoverShareEnabled = false
        activeDriver = nil
        pendingControlRequest = nil
        secureInputBanner = .none
        showJoinSheet = true
    }

    // MARK: - Pumps

    private func startConnectionPump() {
        let stream = transport.connectionStates()
        pumps.append(Task { @MainActor [weak self] in
            for await state in stream {
                guard let self else { continue }
                self.mediaState = state
                self.applyMediaStateToLifecycles(state)
                if case .failed(let r) = state { self.fail(r) }
            }
        })
    }

    /// Broadcast the media link's reconnecting state to every open window's lifecycle so a track that
    /// drops mid-reconnect parks in `.stale` (frozen frame + badge) rather than tearing down (§3 M9).
    private func applyMediaStateToLifecycles(_ state: MediaConnectionState) {
        let reconnecting = (state == .reconnecting)
        for windowID in lifecycles.keys {
            feed(windowID, .transportReconnecting(reconnecting))
            remoteWindows[windowID]?.isReconnecting = reconnecting && (lifecycles[windowID]?.state == .stale)
        }
    }

    private func startParticipantPump() {
        // Roster is now driven by the transport's participant-changed hook (installed in `connect`),
        // which reports the full connected set (local + all remotes) on every connect/disconnect and
        // on (re)connect. `applyParticipantSet` merges it in. Share-owner derivation still runs too
        // (a joiner learns owners from state snapshots), so the two are unioned — never fight.
    }

    /// Record the authoritative connected-participant set from the transport and recompute the roster.
    /// This is the LIVE membership source (local + all connected remotes), so disconnects actually
    /// remove people — unlike the additive snapshot path.
    private func applyParticipantSet(_ ids: Set<ParticipantID>) {
        // Belt-and-braces (§3 M9): anyone who left since the last set gets `ownerDisconnected` fed to
        // any window they own (a defensive path alongside trackGone — if the SDK dropped the track
        // events, the participant diff still tears their windows down) and is pruned from the mirror
        // WITHOUT bumping revision (receiver-local; the host stays the revision authority).
        let departed = transportParticipants.subtracting(ids)
        let newMemberAppeared = !ids.subtracting(transportParticipants).isEmpty
        transportParticipants = ids
        for owner in departed {
            for (windowID, win) in remoteWindows where win.ownerID == owner {
                feed(windowID, .ownerDisconnected)
            }
            // Drop their camera tile too (M10).
            cameraTracks[owner] = nil
            cameraTrackSIDs[owner] = nil
            room.pruneParticipant(owner) // no revision bump
        }
        recomputeRoster()
        // Late-joiner resync (D20): when a NEW participant appeared and we know shares worth
        // advertising, rebroadcast our snapshot so the joiner learns every existing share (nothing
        // else re-broadcasts on join — a late joiner got the video track but never the share list).
        // The joiner itself has an empty room and stays silent, and each existing member
        // rebroadcasts at most once per join, so this can't storm.
        if newMemberAppeared && !room.shares.isEmpty { broadcastState() }
        Task { [weak self] in await self?.refreshDisplayNames() }
    }

    /// The displayed roster = live transport members ∪ current share owners ∪ me. Share owners are
    /// unioned in because a joiner can learn an owner from a state snapshot slightly before (or
    /// without) a bound media-plane identity; they drop off when their share vanishes + they're not a
    /// live transport member.
    private func recomputeRoster() {
        var roster = transportParticipants
        roster.formUnion(room.shares.values)
        if let me = localParticipantID { roster.insert(me) }
        // Assign a deterministic batch order when several peers arrive together, then retain every
        // assignment for the session so later joins cannot recolor existing people.
        for id in roster.sorted(by: { $0.uuidString < $1.uuidString }) {
            _ = participantColorSlot(for: id)
        }
        participants = roster
    }

    private func startStatePump(_ channel: any WireDataChannel) {
        let incoming = channel.incoming()
        pumps.append(Task { @MainActor [weak self] in
            for await data in incoming {
                self?.applyStatePayload(data)
            }
        })
    }

    private func startCursorInPump(_ pump: CursorPump) {
        pumps.append(Task { @MainActor [weak self] in
            await pump.runInbound { windowID, participantID, point in
                self?.windowManager.updateRemoteCursor(windowID: windowID, participant: participantID, point: point)
            }
        })
    }

    // MARK: - Remote control (F4)

    private func startInputPump(_ channel: any WireDataChannel) {
        // The owner-state + bounds providers are captured weakly via the pump's @Sendable closures.
        // NOTE: full owner-state (capability grants + real window bounds) is wired as consent lands;
        // for now the authorizer defaults to remote-control-DISABLED, so nothing injects until the
        // owner explicitly grants — the safe default (D12: Watch is default, master switch off).
        let pump = InputPump(
            channel: channel,
            localID: localParticipantID,
            ownerStateProvider: { InputAuthorizer.OwnerState(remoteControlEnabled: false) },
            boundsProvider: { _ in nil })
        self.inputPump = pump
        pumps.append(Task { @MainActor [weak self] in
            await pump.runInbound(onControlRequest: { req in
                self?.handleControlRequest(req)
            })
        })
        // Secure-input polling (R8): a debounced 1s tick updates the banner while someone is driving.
        pumps.append(Task { @MainActor [weak self] in
            let detector = SecureInputDetector()
            while !Task.isCancelled {
                let active = detector.isSecureInputActive()
                self?.updateSecureInputBanner(secureInputActive: active)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        })
    }

    private func handleControlRequest(_ req: ControlRequest) {
        switch req.action {
        case .request:
            // Only prompt if it targets one of MY windows.
            guard room.owner(of: req.windowID) == localParticipantID else { return }
            pendingControlRequest = req
        case .release:
            if activeDriver == req.participantID { activeDriver = nil }
            pendingControlRequest = nil
            updateSecureInputBanner(secureInputActive: false)
        }
    }

    /// Owner approves a pending control request → record the driver (display badge) and broadcast the
    /// DISPLAY-ONLY controller mirror so everyone sees "being driven by X" (F5/F10). The actual
    /// injection grant (enabling remoteControl + a .write capability) lands with the consent-UI
    /// wiring; authorization NEVER reads the mirror (D12).
    public func approveControlRequest() {
        guard let req = pendingControlRequest else { return }
        activeDriver = req.participantID
        // Broadcast the display-only controller for the requested window (owner-side mirror).
        if room.owner(of: req.windowID) == localParticipantID,
           room.setController(req.participantID, window: req.windowID) {
            broadcastState()
        }
        pendingControlRequest = nil
    }

    public func denyControlRequest() {
        pendingControlRequest = nil
    }

    private func updateSecureInputBanner(secureInputActive: Bool) {
        let banner = SecureInputBanner.decide(
            secureInputActive: secureInputActive, someoneIsDriving: activeDriver != nil)
        // Same-value guard: the R8 poll re-decides every second; only a real transition may touch
        // the observable (each set invalidates the session detail's safe-area inset).
        if secureInputBanner != banner { secureInputBanner = banner }
    }

    /// The display label for the current driver (for the "X is driving" badge), or nil.
    public var activeDriverLabel: String? {
        activeDriver.map { displayLabel(for: $0) }
    }

    // MARK: - Clipboard sync (F6)

    /// Toggle cross-user clipboard sync for THIS session (never persisted). Off → no polling, no send.
    public func setClipboardSyncEnabled(_ on: Bool) {
        clipboardSyncEnabled = on
        clipboardPump?.setEnabled(on)
    }

    // MARK: - Draw / annotation (F9)

    private func startDrawInPump(_ pump: DrawPump) {
        pumps.append(Task { @MainActor [weak self] in
            await pump.runInbound(
                mutate: { apply in self?.drawState.apply(apply) },
                onStroke: { op in self?.drawState.scheduleExpiry(for: op) },
                onChange: { _ in
                    // Sharer-side ink overlay (F9): repaint the real windows peers are drawing on.
                    self?.inkOverlay.sync()
                })
        })
    }

    /// Toggle local draw mode (capture strokes vs. pass hover through).
    public func toggleDrawMode() { drawState.drawModeEnabled.toggle() }

    /// Toggle the hover "Share" tab (backlog #10). Session-scoped; R4-safe (opens the picker) until
    /// the Phase-0 R4 prompt-cadence spike flips HoverShareController.strategy to .direct.
    public func setHoverShareEnabled(_ on: Bool) {
        hoverShareEnabled = on
        hoverShare.setEnabled(on)
    }

    /// Send a completed local stroke (from the DrawOverlay drag) in the local participant's color.
    /// The seq is assigned HERE so the optimistic local apply and the transmitted op are identical —
    /// the inbound echo is then a same-seq no-op (rejectedStaleSequence), not a duplicate stroke.
    public func sendStroke(windowID: WindowID, points: [NormalizedPoint]) {
        guard let me = localParticipantID, points.count > 1 else { return }
        let color = participantRGBAColor(for: me)
        let op = DrawOp(authorID: me, authorSeq: drawSequencer.advance(), windowID: windowID,
                        points: points, color: color, width: 3)
        drawState.apply { $0.apply(op) }
        drawState.scheduleExpiry(for: op)
        inkOverlay.sync() // sharer drawing on their own tile: ink the real window immediately
        Task { await drawPump?.send(op) }
    }

    /// Undo the local author's most recent stroke in a window (per-author undo).
    public func undoDraw(windowID: WindowID) {
        guard let me = localParticipantID else { return }
        let undo = DrawUndo(authorID: me, windowID: windowID)
        drawState.apply { $0.apply(undo) }
        inkOverlay.sync()
        Task { await drawPump?.send(undo) }
    }

    /// Clear the local author's ink in a window (per-author clear).
    public func clearDraw(windowID: WindowID) {
        guard let me = localParticipantID else { return }
        let clear = DrawClear(authorID: me, windowID: windowID)
        drawState.apply { $0.apply(clear) }
        inkOverlay.sync()
        Task { await drawPump?.send(clear) }
    }

    /// Apply an inbound `state`-channel payload: a RoomSnapshot (full state, union-merged) or a
    /// ShareEvent (open/close a viewer window promptly).
    private func applyStatePayload(_ data: Data) {
        guard let envelope = try? WireCodec.decode(data), let kind = envelope.kind else {
            return // unknown/unreadable — skip, never crash
        }
        switch kind {
        case .roomSnapshot:
            guard let snap = try? WireCodec.unpack(envelope, as: RoomSnapshot.self) else { return }
            // Union-merge (D20): per-process revisions collide across concurrent sharers, so the
            // old strictly-newer revision gate silently dropped foreign shares. Apply every
            // snapshot; `merge` keeps our copy authoritative for our own shares and never removes
            // (unshares arrive as ordered ShareEvents).
            applyRoom(snap.model)
            // Late-joiner ink catch-up (F9): if we hold no ink yet and the snapshot carries some,
            // seed it. DrawModel.apply is monotonic per-author, so re-seeding once is safe; we only
            // do it while empty to avoid clobbering live local strokes with a stale snapshot.
            if let ink = snap.draw, !ink.isEmpty, drawState.model.isEmpty {
                drawState.apply { $0 = ink }
                // The ephemeral contract holds for seeded ink too: each stroke's 15s lifetime
                // counts from local receipt, so nothing seeded can outlive the room's ink.
                for window in ink.windowsWithInk {
                    for op in ink.strokes(in: window) { drawState.scheduleExpiry(for: op) }
                }
            }
        case .shareEvent:
            guard let ev = try? WireCodec.unpack(envelope, as: ShareEvent.self) else { return }
            applyShareEvent(ev)
        default:
            break
        }
    }

    /// Apply a remote share/unshare event to the mirrored room (D20). Events about windows WE are
    /// capturing locally are ignored — our own shares are local-authoritative, so a replayed or
    /// stale event must never re-own or end a live local share.
    private func applyShareEvent(_ ev: ShareEvent) {
        guard localCaptures[ev.windowID] == nil else { return }
        switch ev.action {
        case .shared:
            // The track subscription opens the viewer window; the event carries the authoritative
            // owner + advisory info, so record the share here — previously `.shared` was ignored
            // and the share list only filled in via (revision-gated, droppable) snapshots.
            if room.applyForeignShare(ev.windowID, owner: ev.ownerID, info: ev.info) {
                repairWindowChrome(ev.windowID)
                recomputeRoster()
            }
        case .unshared:
            room.pruneShare(ev.windowID) // no revision bump (receiver-local)
            recomputeRoster()
            // Prompt lifecycle removal — without waiting for any snapshot.
            if lifecycles[ev.windowID] != nil {
                feed(ev.windowID, .shareRemovedFromSnapshot)
            }
        }
    }

    /// Merge a foreign snapshot into the mirrored room (D20), then repair owner attribution, title,
    /// aspect, and pause state on open viewer windows. The local participant's own shares are
    /// excluded from the merge — they are local-authoritative.
    private func applyRoom(_ newRoom: RoomModel) {
        room.merge(snapshot: newRoom, excludingOwner: localParticipantID)
        recomputeRoster()
        // Owner + metadata repair: a track that subscribed before the first snapshot had a
        // placeholder owner/title; every snapshot repairs it so chrome recolors/retitles live.
        for windowID in remoteWindows.keys { repairWindowChrome(windowID) }
    }

    /// Re-derive one open viewer window's owner/title/aspect/pause badge from the merged room state.
    private func repairWindowChrome(_ windowID: WindowID) {
        guard let win = remoteWindows[windowID] else { return }
        if let owner = room.owner(of: windowID), owner != win.ownerID {
            win.ownerID = owner
            windowManager.refreshTitle(win)
        }
        if let info = room.info(of: windowID) {
            let newTitle = info.title, newApp = info.appName, aspect = info.sourceAspectRatio
            if win.title != newTitle || win.appName != newApp { win.title = newTitle; win.appName = newApp; windowManager.refreshTitle(win) }
            if let aspect, win.aspectRatio != aspect { win.aspectRatio = aspect }
        }
        // Pause badge from broadcast state (previously ignored).
        win.isPaused = (room.pauseState(of: windowID) == .paused)
    }

    // MARK: - Remote windows (lifecycle-driven, M9)

    /// Feed one event into a window's lifecycle reducer and execute the resulting effects. The
    /// reducer holds ALL the correctness (grace parking, no-duplicate-window, soft/hard hide); this
    /// just runs the effects against the NSWindow layer + transport.
    private func feed(_ windowID: WindowID, _ event: RemoteWindowLifecycle.Event) {
        guard var lifecycle = lifecycles[windowID] else { return }
        let effects = lifecycle.reduce(event)
        lifecycles[windowID] = lifecycle
        execute(effects, for: windowID)
    }

    private func execute(_ effects: [RemoteWindowLifecycle.Effect], for windowID: WindowID) {
        for effect in effects {
            switch effect {
            case .openWindow:
                if let win = remoteWindows[windowID] { windowManager.open(win) }
            case .closeWindow:
                windowManager.close(windowID)
            case .unsubscribe:
                // Hard unsubscribe = zero downlink, no decode. Mark the entry inactive so the decode
                // budget and any thumbnail renderer treat it as not-decoding until it resubscribes.
                remoteWindows[windowID]?.isRenderingActive = false
                Task { await transport.setWindowTrackSubscribed(windowID: windowID, false) }
            case .resubscribe:
                Task { await transport.setWindowTrackSubscribed(windowID: windowID, true) }
            case .pauseRendering:
                remoteWindows[windowID]?.isRenderingActive = false
            case .resumeRendering:
                remoteWindows[windowID]?.isRenderingActive = true
            case .purge:
                purgeRemoteWindow(windowID)
            }
        }
    }

    private func addRemoteWindow(windowID: WindowID, ownerHint: ParticipantID?,
                                 track: JoeScreenLiveKit.RemoteVideoTrackRef) {
        // Reopen / reconnect resubscribe: the SDK re-delivered a track for a window whose entry we
        // still hold. Swap it in-place (no duplicate window) and let the reducer resume.
        if let existing = remoteWindows[windowID] {
            existing.track = track
            existing.isReconnecting = false
            existing.isRenderingActive = true // the track is back → decoding again (reopen/reconnect)
            windowManager.replaceContent(existing)
            cancelGrace(windowID)
            feed(windowID, .trackSubscribed)
            return
        }
        AppLog.info("remote track subscribed → opening native window for \(windowID)")
        // Owner attribution priority: authoritative room state > descriptor identity > windowID
        // placeholder for coloring only (repaired by applyRoom / ShareEvents). The placeholder is
        // NEVER inserted into the roster — the old `?? windowID` fallback injected a phantom
        // ParticipantID via transportParticipants (D20).
        let owner = room.owner(of: windowID) ?? ownerHint
        // Reconcile list ↔ windows: if room state doesn't know this share yet, record it now so
        // the share list and the open window agree even before the snapshot/ShareEvent lands.
        if let owner, room.owner(of: windowID) == nil {
            room.applyForeignShare(windowID, owner: owner) // no revision bump (receiver-local)
        }
        let info = room.info(of: windowID)
        let win = RemoteVideoWindow(
            windowID: windowID, ownerID: owner ?? windowID, track: track,
            aspectRatio: info?.sourceAspectRatio, title: info?.title, appName: info?.appName)
        win.isPaused = (room.pauseState(of: windowID) == .paused)
        remoteWindows[windowID] = win
        lifecycles[windowID] = RemoteWindowLifecycle(
            reconnecting: mediaState == .reconnecting)
        if let owner { transportParticipants.insert(owner) }
        recomputeRoster()
        feed(windowID, .trackSubscribed) // → openWindow effect
    }

    // MARK: - Participant media (M10)

    /// Apply the reactive media-state snapshot from the transport, and fold any display names it
    /// carries into the name cache so `displayLabel` updates live on `didUpdateName` / late-join.
    private func applyParticipantMedia(_ states: [ParticipantID: ParticipantMediaState]) {
        // LiveKit re-reports the active-speaker set every few hundred ms during speech, mostly
        // with an unchanged snapshot. Replacing the whole observable dictionary anyway would
        // re-render every tile/PiP/roster reader on each report — skip the no-ops.
        guard states != participantMedia else { return }
        participantMedia = states
        for (id, s) in states where s.displayName != nil {
            displayNames[id] = s.displayName
        }
    }

    /// Live media state for a participant (nil if unknown).
    public func mediaState(for id: ParticipantID) -> ParticipantMediaState? { participantMedia[id] }

    /// The remote camera track for a participant, if any.
    public func cameraTrack(for id: ParticipantID) -> JoeScreenLiveKit.RemoteVideoTrackRef? {
        cameraTracks[id]
    }

    /// The planned tile order + decode budget for the strip (self first, remotes name-then-UUID,
    /// cameras beyond the budget park as avatars; shares take priority). Pure `TileSubscriptionPlanner`.
    public var plannedTiles: [TileSubscriptionPlanner.Tile] {
        let me = localParticipantID
        let remotes = participants.subtracting(me.map { [$0] } ?? []).sorted { $0.uuidString < $1.uuidString }
        return TileSubscriptionPlanner.plan(
            selfID: me,
            remotes: remotes,
            displayName: { [weak self] in self?.displayNames[$0] },
            hasRenderableCamera: { [weak self] in self?.cameraTracks[$0] != nil },
            // Only windows actually decoding count against the budget — a user-closed (hard-
            // unsubscribed) or soft-hidden window consumes no decode/downlink.
            sharesDecoded: decodingShareCount)
    }

    /// Raise all shared windows owned by `owner` (tap a participant tile).
    public func focusSharesOf(owner: ParticipantID) {
        for (windowID, win) in remoteWindows where win.ownerID == owner {
            windowManager.focus(windowID)
        }
    }

    /// The remote video track backing a shared window's live thumbnail (M10) — a SECOND renderer on
    /// the already-held track (one decode, two renderers; adaptive-stream reports the max renderer
    /// size so the big window keeps its quality; R32 satisfied by construction). Nil if not (yet) open.
    public func remoteWindowTrack(_ windowID: WindowID) -> JoeScreenLiveKit.RemoteVideoTrackRef? {
        remoteWindows[windowID]?.track
    }

    /// Whether `windowID` is a window WE are sharing (owned by the local participant). The sharer's own
    /// share tile has no *remote* track (you don't subscribe to your own publications), so it self-
    /// previews the LOCAL published track instead — see `localWindowTrack`.
    public func isLocallyOwnedShare(_ windowID: WindowID) -> Bool {
        // Local capture bookkeeping is authoritative on the sharer. The replicated RoomModel can
        // momentarily lag a just-started share (or be repaired by a foreign snapshot), but that must
        // never make our tile take the remote-rendering path and lose its self-preview.
        localShareKinds[windowID] != nil
            || localWindowTracks[windowID] != nil
            || (localParticipantID != nil && room.owner(of: windowID) == localParticipantID)
    }

    /// The LOCAL published track for a window WE share, for the sharer's own live thumbnail preview.
    /// Nil for remote windows (use `remoteWindowTrack`) or if the local track isn't published yet.
    /// Cached into an observable map when the share goes live (the transport is an actor, so it can't
    /// be read synchronously from a view) — mirrors how `localCameraTrack` backs the camera preview.
    public func localWindowTrack(_ windowID: WindowID) -> VideoTrack? {
        localWindowTracks[windowID]
    }

    /// The source aspect ratio of a shared window (for an aspect-true thumbnail), if known.
    public func remoteWindowAspect(_ windowID: WindowID) -> Double? {
        remoteWindows[windowID]?.aspectRatio
    }

    /// Whether a shared window is actively rendering (open, not soft-hidden). The share thumbnail
    /// must gate its SECOND renderer on this too: a soft-hidden (miniaturized/occluded) window
    /// detaches its big renderer so adaptive-stream stops SFU forwarding — a thumbnail renderer left
    /// attached would keep the stream flowing and defeat the R24/R32 soft-hide.
    public func isRemoteWindowRenderingActive(_ windowID: WindowID) -> Bool {
        remoteWindows[windowID]?.isRenderingActive ?? false
    }

    /// Count of shared windows ACTUALLY decoding right now (open AND rendering) — used for the decode
    /// budget. A user-closed window stays in `remoteWindows` (reopenable) but is hard-unsubscribed at
    /// the SFU (zero decode), so it must NOT count against the budget.
    private var decodingShareCount: Int {
        remoteWindows.values.filter { $0.isRenderingActive }.count
    }

    // MARK: - Camera tiles (M10)

    /// Record a remote participant's camera track for their tile. Keyed by owner; a newer SID for the
    /// same owner (camera re-enable / republish) replaces the prior one.
    private func addCameraTrack(owner: ParticipantID, sid: String, track: JoeScreenLiveKit.RemoteVideoTrackRef) {
        cameraTracks[owner] = track
        cameraTrackSIDs[owner] = sid
        transportParticipants.insert(owner)
        recomputeRoster()
    }

    /// Drop a remote participant's camera track when its SID goes away (only if it's still the
    /// current one — a stale gone for a replaced SID is ignored).
    private func removeCameraTrack(owner: ParticipantID, sid: String) {
        guard cameraTrackSIDs[owner] == sid else { return }
        cameraTracks[owner] = nil
        cameraTrackSIDs[owner] = nil
    }

    /// A remote sharer's track went away (stop / crash / codec renegotiation republish). The reducer
    /// parks it `.stale` (frozen frame); we arm a grace timer — a long one during an SFU-link
    /// reconnect (blip), a short one otherwise (catch a renegotiation resubscribe / confirm a crash).
    private func handleRemoteTrackGone(windowID: WindowID) {
        guard lifecycles[windowID] != nil else { return }
        feed(windowID, .trackGone(.trackEnded))
        if lifecycles[windowID]?.state == .stale {
            let reconnecting = (mediaState == .reconnecting)
            // Show the "Reconnecting…" badge only for a real link reconnect; a renegotiation swap just
            // freezes briefly (no alarming badge).
            remoteWindows[windowID]?.isReconnecting = reconnecting
            armGrace(windowID, seconds: reconnecting ? Self.reconnectGraceSeconds : Self.renegotiationGraceSeconds)
        }
    }

    /// The user closed the viewer window (NSWindowDelegate.windowWillClose) — keep a reopenable entry.
    /// Called by `RemoteWindowManager`'s per-window delegate (same app module).
    func remoteWindowDelegateEvent(_ windowID: WindowID, _ event: RemoteWindowDelegate.Event) {
        switch event {
        case .userClosed:
            // The window is already closing; execute the reducer WITHOUT a redundant closeWindow (the
            // manager cut the delegate before a programmatic close, so this only fires on a real user
            // close). We still cut downlink + keep the entry.
            feed(windowID, .userClosed)
        case .miniaturized(let value):
            feed(windowID, .miniaturized(value))
        case .occluded(let value):
            feed(windowID, .occluded(value))
        }
    }

    /// Reopen a user-closed viewer window (SharedWindowTile / Window menu). Re-subscribes; the new
    /// track routes into the existing entry via `addRemoteWindow`'s reopen branch.
    public func reopenRemoteWindow(_ windowID: WindowID) {
        guard lifecycles[windowID]?.state == .closedByUser else { return }
        feed(windowID, .userReopened) // → resubscribe effect
    }

    /// Terminal purge: drop the entry, lifecycle, timers. The window itself is closed by the
    /// closeWindow effect (or was already closing on a user-close path).
    private func purgeRemoteWindow(_ windowID: WindowID) {
        remoteWindows[windowID] = nil
        lifecycles[windowID] = nil
        cancelGrace(windowID)
    }

    // MARK: - Reconnect / renegotiation grace

    private func armGrace(_ windowID: WindowID, seconds: UInt64) {
        cancelGrace(windowID)
        graceTimers[windowID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.feed(windowID, .graceExpired)
        }
    }

    private func cancelGrace(_ windowID: WindowID) {
        graceTimers[windowID]?.cancel()
        graceTimers[windowID] = nil
    }

    /// The window manager asks for a window's cascade indices (owner index among current owners,
    /// window index within that owner) so `WindowCascade` places it deterministically.
    func cascadeIndices(for windowID: WindowID, owner: ParticipantID) -> (ownerIndex: Int, windowIndex: Int) {
        // Owners currently rendered, sorted for a stable index.
        let owners = Set(remoteWindows.values.map { $0.ownerID }).sorted { $0.uuidString < $1.uuidString }
        let ownerIndex = owners.firstIndex(of: owner) ?? 0
        let ownerWindows = remoteWindows.keys
            .filter { remoteWindows[$0]?.ownerID == owner }
            .sorted { $0.uuidString < $1.uuidString }
        let windowIndex = ownerWindows.firstIndex(of: windowID) ?? 0
        return (ownerIndex, windowIndex)
    }

    // MARK: - Window menu / focus actions

    /// Whether newly-opened remote windows steal focus ("Follow New Shares", session pref).
    public var followNewShares: Bool = false

    public func focusRemoteWindow(_ windowID: WindowID) { windowManager.focus(windowID) }
    public func bringAllSharedWindowsToFront() { windowManager.bringAllToFront() }
    public func setFollowNewShares(_ follow: Bool) {
        followNewShares = follow
        windowManager.followNewShares = follow
    }
    public func setAlwaysOnTop(_ windowID: WindowID, _ onTop: Bool) {
        windowManager.setAlwaysOnTop(windowID, onTop)
    }

    /// Whether a window is in the user-closed state (drives the tile's Reopen vs Focus button).
    public func isRemoteWindowClosed(_ windowID: WindowID) -> Bool {
        lifecycles[windowID]?.state == .closedByUser
    }

    // MARK: - Cursors (M6)

    /// Report the local user's pointer over a remote window; the pump coalesces + sends at ~60 fps.
    public func reportLocalCursor(windowID: WindowID, point: NormalizedPoint) {
        guard let pump = cursorPump else { return }
        let ts = ProcessInfo.processInfo.systemUptime
        Task { await pump.sendLocalCursor(windowID: windowID, point: point, timestamp: ts) }
    }

    // MARK: - Local media controls (mic + webcam)

    /// Re-fetch the AUDIO input list. Safe to call anytime — audio-device enumeration needs no TCC
    /// and doesn't touch the camera. Used to pre-fill the mic picker on join and when it opens.
    public func refreshAudioInputs() async {
        let inputs = await transport.availableInputDevices(.audioInput)
        audioInputs = inputs
        if let selectedAudioInputID,
           inputs.contains(where: { $0.id == selectedAudioInputID }) {
            return
        }
        selectedAudioInputID = inputs.first(where: \.isDefault)?.id ?? inputs.first?.id
    }

    /// Re-fetch the VIDEO (camera) input list. Kept OFF the join path and only called when the camera
    /// picker opens or after camera access is granted: `CameraCapturer.captureDevices()` runs an
    /// AVFoundation discovery session that can block, so enumerating it eagerly on join once stalled
    /// the whole session (incl. remote-track rendering). Enumeration itself doesn't prompt for TCC,
    /// but returns a limited/empty list until access is granted (toggleCamera preflights the grant).
    public func refreshVideoInputs() async {
        let inputs = await transport.availableInputDevices(.videoInput)
        videoInputs = inputs

        // Keep the picker selection valid as cameras arrive/disappear. Before the user chooses one,
        // record AVFoundation's default (or the first enumerated camera) so the menu can render a
        // real checkmark and enabling video captures from the camera the UI claims is selected.
        if let selectedVideoInputID,
           inputs.contains(where: { $0.id == selectedVideoInputID }) {
            return
        }
        selectedVideoInputID = inputs.first(where: \.isDefault)?.id ?? inputs.first?.id
    }

    /// Pre-fill both pickers. Audio is fetched inline; video is fetched in a detached task so a slow
    /// AVFoundation camera-discovery call can never block the caller (e.g. the join sequence).
    public func refreshInputDevices() async {
        await refreshAudioInputs()
        Task { [weak self] in await self?.refreshVideoInputs() }
    }

    /// Toggle the microphone on/off. Acts on the EFFECTIVE state (`micLive`): if the co-located
    /// gate is currently holding the mic muted, the toggle means "go live" — it lifts the gate's
    /// hold and unmutes — rather than blindly inverting the stale manual intent and re-muting.
    /// LiveKit MUTES the mic publication on disable (it doesn't unpublish), so the live/muted
    /// state is read back from `isMicrophoneEnabled()` — not from publication existence, which
    /// would report "on" even while muted and wedge the toggle.
    public func toggleMic() {
        let target = !micLive
        // A manual toggle is user intent: drop the gate's mute bookkeeping so it can neither hold
        // the mic muted against the user nor unmute a manual mute later.
        let gateHeldMute = gateAppliedMicMute
        gateAppliedMicMute = false
        gateMuted = false
        audioGate.release()
        // Optimistic UI: flip immediately so the icon responds even if the round-trip is slow, then
        // reconcile with the transport's real state.
        micEnabled = target
        Task {
            do {
                // Lift a gate-applied publication mute explicitly — setMicrophone(enabled:) alone
                // doesn't reliably clear a mute the gate applied directly to the publication.
                if target, gateHeldMute { try await transport.setMicrophoneGateMuted(false) }
                try await transport.setMicrophone(enabled: target)
            } catch {
                AppLog.error("toggleMic failed: \(String(describing: error))")
            }
            micEnabled = await transport.isMicrophoneEnabled()
        }
    }

    // MARK: - Voice isolation (Apple voice processing)

    /// Whether Apple voice processing (echo cancellation, noise suppression, AGC — and the gateway
    /// to the system Voice Isolation mic mode) is on for the local mic. Defaults ON; persisted.
    public private(set) var voiceIsolationEnabled =
        UserDefaults.standard.object(forKey: AppModel.voiceIsolationDefaultsKey) as? Bool ?? true
    private static let voiceIsolationDefaultsKey = "JoeScreen.voiceIsolation"

    public func setVoiceIsolation(enabled: Bool) {
        voiceIsolationEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.voiceIsolationDefaultsKey)
        Task { await transport.setVoiceIsolation(enabled: enabled) }
    }

    // MARK: - Co-located audio gate (D21 — echo/crosstalk mitigation for same-room participants)

    public func isCoLocated(_ id: ParticipantID) -> Bool {
        coLocatedParticipants.contains(id)
    }

    /// Mark/unmark a participant as co-located (same physical room). Persisted in UserDefaults.
    public func setCoLocated(_ id: ParticipantID, _ isCoLocated: Bool) {
        if isCoLocated {
            coLocatedParticipants.insert(id)
        } else {
            coLocatedParticipants.remove(id)
        }
        UserDefaults.standard.set(coLocatedParticipants.map(\.uuidString),
                                  forKey: Self.coLocatedDefaultsKey)
    }

    /// Poll the room's speaking state at 10 Hz and drive the co-located-speaker gate. The SDK
    /// exposes levels as participant properties (`Participant.audioLevel` / `isSpeaking`), so a
    /// light poll keeps this fully additive — no transport delegate plumbing. Cancelled with the
    /// other pumps on leave.
    private func startAudioGatePump() {
        pumps.append(Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                await self.audioGateTick()
            }
        })
    }

    /// One gate step: feed levels in, apply the output. Transitions only, and never fight the
    /// user's manual mute — the gate may mute only while the mic is user-enabled, and may unmute
    /// only a mute it applied itself.
    private func audioGateTick() async {
        let activity = await transport.audioActivitySnapshot()
        updateActiveSpeaker(
            localIsSpeaking: activity.localIsSpeaking,
            localLevel: activity.localLevel,
            remotes: activity.remotes)
        let shouldMute = audioGate.evaluate(
            localIsSpeaking: activity.localIsSpeaking,
            localLevel: activity.localLevel,
            remotes: activity.remotes,
            coLocated: coLocatedParticipants,
            now: ProcessInfo.processInfo.systemUptime)
        if shouldMute, micEnabled, !gateAppliedMicMute {
            do {
                try await transport.setMicrophoneGateMuted(true)
                gateAppliedMicMute = true
            } catch {
                AppLog.error("gate mic mute failed: \(String(describing: error))")
            }
        } else if !shouldMute, gateAppliedMicMute {
            do {
                try await transport.setMicrophoneGateMuted(false)
                gateAppliedMicMute = false
            } catch {
                AppLog.error("gate mic unmute failed: \(String(describing: error))")
            }
        }
        // @Observable notifies on every SET, not on value change — an unconditional write here
        // re-invalidated every micLive/gateMuted reader (toolbar, tiles) at the 10 Hz pump rate.
        if gateMuted != gateAppliedMicMute { gateMuted = gateAppliedMicMute }
    }

    /// Pick the loudest participant LiveKit currently considers speech. A small level floor catches
    /// SDK speaking-flag jitter; retaining the prior value through silence prevents the PiP flashing
    /// to an empty state between words and sentences.
    private func updateActiveSpeaker(
        localIsSpeaking: Bool,
        localLevel: Float,
        remotes: [CoLocatedAudioGate.RemoteAudioSample]
    ) {
        var candidates: [(id: ParticipantID, level: Float)] = remotes.compactMap { sample in
            guard sample.isSpeaking || sample.level > 0.01 else { return nil }
            return (sample.participantID, sample.level)
        }
        if let localParticipantID, localIsSpeaking || localLevel > 0.01 {
            candidates.append((localParticipantID, localLevel))
        }
        guard let loudest = candidates.max(by: { lhs, rhs in
            if lhs.level == rhs.level { return lhs.id.uuidString > rhs.id.uuidString }
            return lhs.level < rhs.level
        }) else { return }
        // Same-value guard: while one person talks, the pump re-picks them 10×/s — writing the
        // unchanged ID would re-invalidate the PiP panel and its video view every tick.
        if activeSpeakerParticipantID != loudest.id { activeSpeakerParticipantID = loudest.id }
    }

    /// Route the mic to a specific input device (nil = keep current). Persists the selection so the
    /// checkmark and future captures follow it.
    public func selectAudioInput(_ deviceID: String) {
        selectedAudioInputID = deviceID
        Task { await transport.selectAudioInput(deviceID: deviceID) }
    }

    /// Toggle the webcam on/off. Enabling preflights camera TCC (deterministic system prompt) and,
    /// on success, publishes a camera track + exposes the local track for the self-preview tile.
    public func toggleCamera() {
        guard !cameraBusy else { return } // one in-flight transition at a time
        let target = !cameraEnabled
        cameraBusy = true
        Task {
            defer { cameraBusy = false }
            if target {
                let granted = await Self.ensureCameraAccess()
                guard granted else {
                    AppLog.error("camera access denied; not enabling webcam")
                    return
                }
                // A freshly granted permission makes new cameras enumerable — refresh that picker.
                await refreshVideoInputs()
            }
            do {
                try await transport.setCamera(enabled: target, deviceID: selectedVideoInputID)
            } catch {
                AppLog.error("toggleCamera failed: \(String(describing: error))")
            }
            cameraEnabled = await transport.isCameraPublished()
            localCameraTrack = cameraEnabled ? await transport.localCameraVideoTrack() : nil
            if cameraEnabled, localCameraTrack != nil {
                // Participant video lives in the inspector. If SwiftUI hid it while reconciling a
                // narrow window, reveal it when the user explicitly turns their camera on so the
                // successful capture never looks broken. Preserve an explicit saved preference.
                setInspectorPresented(true, persistPreference: false)
            }
            // An implicit (default-device) enable never set selectedVideoInputID — read the device
            // the capturer actually opened so the picker's checkmark reflects reality.
            if cameraEnabled, selectedVideoInputID == nil {
                selectedVideoInputID = await transport.activeCameraDeviceID()
            }
        }
    }

    /// Switch the active webcam. If the camera is already on, republishes from the new device;
    /// otherwise just records the selection for the next enable.
    public func selectVideoInput(_ deviceID: String) {
        selectedVideoInputID = deviceID
        guard cameraEnabled, !cameraBusy else { return }
        cameraBusy = true
        Task {
            defer { cameraBusy = false }
            do {
                try await transport.setCamera(enabled: true, deviceID: deviceID)
                localCameraTrack = await transport.localCameraVideoTrack()
            } catch {
                AppLog.error("selectVideoInput failed: \(String(describing: error))")
            }
        }
    }

    /// Request camera TCC up front so the system prompt fires deterministically (mirrors the
    /// Screen-Recording preflight in `startSharing`). Returns whether access is authorized.
    private static func ensureCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    // MARK: - Sharing

    /// Present the ScreenCaptureKit picker and share the chosen window (M3/M4).
    public func beginShare() {
        Task { await beginShareViaPicker() }
    }

    /// Share a specific OS window by CGWindowID (the picker callback AND the --share-window-id
    /// automation bypass both land here). The SCWindow is resolved inside the capture actor, so no
    /// non-Sendable object crosses an isolation boundary.
    public func shareWindow(cgWindowID: CGWindowID) {
        Task { await startSharing(cgWindowID: cgWindowID) }
    }

    private func beginShareViaPicker() async {
        // The picker (SCContentSharingPicker) calls back with the chosen window OR display (M11).
        SharePicker.shared.present(onPick: { [weak self] pick in
            Task { @MainActor in
                switch pick {
                case .window(let cgWindowID): self?.shareWindow(cgWindowID: cgWindowID)
                case .display(let displayID): self?.shareDisplay(displayID: displayID)
                }
            }
        }, onAmbiguous: { [weak self] in
            Task { @MainActor in
                self?.shareRefusedReason = "Couldn't identify the selected screen. Please pick it again."
            }
        })
    }

    /// Share a whole display by CGDirectDisplayID (the picker callback AND the --share-display-id /
    /// --share-main-display automation bypass land here). Full capture path lands in M11.5.
    public func shareDisplay(displayID: CGDirectDisplayID) {
        Task { await startSharingDisplay(displayID: displayID) }
    }

    private func startSharing(cgWindowID: CGWindowID) async {
        guard let me = localParticipantID else { return }
        // NOTE: we deliberately do NOT preflight with CGPreflightScreenCaptureAccess() /
        // CGRequestScreenCaptureAccess() here. That CoreGraphics preflight uses a DIFFERENT TCC
        // evaluation than ScreenCaptureKit (which is what actually captures), and routinely reports
        // `false` even when the app IS granted Screen Recording in System Settings — firing a spurious
        // "would like to record this computer's screen" prompt on every share. Instead we let
        // SCShareableContent / SCStream.startCapture() be the sole authority: it succeeds when the
        // grant is real, and throws (surfaced below) when it genuinely isn't. See handleScreenCaptureDenial.
        AppLog.info("startSharing cgWindowID=\(cgWindowID)")
        // Encode-session cap is knowable up front — refuse BEFORE touching the codec context so a
        // capped share never renegotiates live tracks (no VP9→H.264→VP9 flicker).
        if let refusal = encodeCapRefusal() { shareRefusedReason = refusal; return }

        let windowID = WindowID()
        let capture = WindowCaptureService(windowID: windowID)
        localCaptures[windowID] = capture
        localShareKinds[windowID] = .window
        localShareScreenTargets[windowID] = .window(cgWindowID)

        // Codec-ordering fix (latent #3): update the share context to INCLUDE this pending window
        // BEFORE publishing, so the transport (which now builds publish options at completePublish,
        // after the first frame) selects the right structural codec for the new track (D5).
        let pending = shareContext.adding(.window)
        await pushShareContext(pending)

        do {
            let sink = try await transport.publishVideoTrack(for: windowID)
            AppLog.info("publishVideoTrack sink ready for window \(windowID); starting capture")
            // Wire capture events → pause state + minimize-unshare.
            let events = await capture.events()
            pumps.append(Task { @MainActor [weak self] in
                for await event in events {
                    switch event {
                    case .paused: self?.setLocalPause(windowID, .paused)
                    case .resumed: self?.setLocalPause(windowID, .live)
                    case .ended: self?.unshare(windowID)
                    case .stopped: self?.unshare(windowID)
                    case .resized(let w, let h): self?.updateShareDimensions(windowID, pixelWidth: w, pixelHeight: h)
                    case .frame: break
                    }
                }
            })
            try await capture.start(cgWindowID: cgWindowID, sink: sink)
            AppLog.info("capture started for cgWindowID=\(cgWindowID); broadcasting share")
            let info = await capture.shareInfo

            // Uplink admission (M11): compute this share's target bitrate and check it fits alongside
            // the existing shares. Degrade the whole set uniformly if needed; refuse (tear down, no
            // dangling capture) if it won't fit even at the floor.
            if !(await admitShare(windowID: windowID, kind: .window, info: info)) {
                await teardownFailedShare(windowID)
                return
            }

            // Commit the context (the share is now live).
            shareContext = pending
            // Cache the local published track so our own share tile shows a live self-preview.
            localWindowTracks[windowID] = await transport.localScreenShareTrack(for: windowID)
            // Update authoritative room + broadcast.
            room.addShare(windowID, owner: me)
            // The navigator may currently filter the center to another participant. A successful
            // local share should always reveal itself instead of remaining live-but-invisible.
            sidebarSelection = .screenShares
            // Populate the advisory ShareInfo (title/app/source pixels) captured at start so receivers
            // can title + aspect-size their viewer window before the first frame (M9).
            if let info { room.setShareInfo(info, window: windowID) }
            broadcastState()
            broadcastShareEvent(.shared, windowID: windowID, owner: me, info: room.info(of: windowID))
        } catch {
            AppLog.error("startSharing failed: \(String(describing: error))")
            if case WindowCaptureService.CaptureError.sensitiveApp = error {
                shareRefusedReason = "That window belongs to a password manager or Keychain and can't be shared."
            } else if isScreenRecordingDenied(error) {
                shareRefusedReason = recoverFromScreenRecordingDenial()
            }
            await teardownFailedShare(windowID)
        }
    }

    /// True if `error` is ScreenCaptureKit reporting a missing/stale Screen Recording grant. SCStream's
    /// `startCapture()` (and `SCShareableContent`) fail with `SCStreamError` code `.userDeclined`
    /// (-3801) when TCC hasn't granted screen recording — OR when a previously-valid grant went STALE
    /// after an app update (the toggle still shows ON in System Settings, but the grant is bound to the
    /// old binary's code-signature/CDHash and macOS no longer honors it for the new build).
    private func isScreenRecordingDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == SCStreamError.errorDomain
            && ns.code == SCStreamError.Code.userDeclined.rawValue
    }

    /// Recover from a screen-recording denial. We do NOT preflight (CGPreflightScreenCaptureAccess is
    /// unreliable and fires a spurious prompt even when granted — the original bug). Instead, only
    /// AFTER SCStream actually denied do we call CGRequestScreenCaptureAccess() ONCE: on a genuine
    /// first-time denial it shows the one legitimate grant prompt; on a STALE grant (toggle ON but
    /// bound to the old binary after an update) it re-establishes the binding to the current build.
    /// Either way the user then retries the share and it works — no manual System-Settings toggling.
    /// Returns the message to surface (asking them to grant + retry).
    private func recoverFromScreenRecordingDenial() -> String {
        // Reactive request (macOS shows the prompt / re-binds the grant). Fire-and-read; the result is
        // advisory — the authoritative retry is the user's next share attempt.
        let granted = CGRequestScreenCaptureAccess()
        AppLog.info("screen-recording denied by SCStream; requested access → \(granted)")
        return granted
            ? "Screen Recording was just re-enabled for this version of JoeScreen. Please try sharing again."
            : "JoeScreen needs Screen Recording permission. Enable it in System Settings › Privacy & Security › Screen Recording (toggle JoeScreen OFF then ON if it's already listed), then try again."
    }

    /// The structural encode-session cap check, knowable UP FRONT (before capture/pixels). Gating on
    /// it before `pushShareContext` means a share refused purely by the cap never renegotiates (and
    /// then un-renegotiates) live tracks — no flicker. Returns a refusal message if capped, else nil.
    private func encodeCapRefusal() -> String? {
        // currentWindowCount = shares already live; the cap refuses when +1 would exceed maxEncodeSessions.
        let decision = admission.admitShare(
            existingBitrates: localShareBitrates.values.map { $0 },
            requestedBitrate: ShareBitratePolicy.floorBps,
            measuredUplinkBps: .greatestFiniteMagnitude, // ignore bandwidth — only the encode cap here
            peerCount: participants.count, topology: .sfu)
        if case .refuseAtCapacity(.encodeSessionCap(let max)) = decision {
            return Self.refusalMessage(.encodeSessionCap(max: max))
        }
        return nil
    }

    /// Run uplink admission for a pending share; on `.degrade` uniformly rescale existing shares'
    /// bitrates; set the admitted bitrate on the transport. Returns false if REFUSED (with a visible
    /// reason set). Screen-content bitrate comes from the source pixel dims via ShareBitratePolicy.
    private func admitShare(windowID: WindowID, kind: ShareKind, info: ShareInfo?) async -> Bool {
        let w = info?.sourcePixelWidth ?? 1920
        let h = info?.sourcePixelHeight ?? 1080
        let requested = ShareBitratePolicy.bitrate(pixelWidth: w, pixelHeight: h)
        let existing = localShareBitrates.values.map { $0 }
        let decision = admission.admitShare(
            existingBitrates: existing, requestedBitrate: requested,
            measuredUplinkBps: Self.assumedUplinkBps, peerCount: participants.count, topology: .sfu)
        switch decision {
        case .admit(let bitrate):
            localShareBitrates[windowID] = bitrate
            await transport.setShareBitrate(windowID: windowID, bps: bitrate)
            shareRefusedReason = nil
            return true
        case .degrade(let perWindow):
            // Uniformly rescale EVERY share (existing + new) to the common fitting bitrate. The new
            // share picks it up at publish; ALREADY-LIVE shares whose bitrate dropped must be
            // republished so the degrade actually protects the uplink (setShareBitrate alone only
            // affects the next publish).
            let liveWindowsToRepublish = localShareBitrates.keys.filter { $0 != windowID && localShareBitrates[$0] != perWindow }
            localShareBitrates[windowID] = perWindow
            for id in localShareBitrates.keys { localShareBitrates[id] = perWindow }
            for id in localShareBitrates.keys { await transport.setShareBitrate(windowID: id, bps: perWindow) }
            if !liveWindowsToRepublish.isEmpty {
                await transport.republishForBitrateChange(windowIDs: Array(liveWindowsToRepublish))
            }
            shareRefusedReason = nil
            return true
        case .refuseAtCapacity(let reason):
            shareRefusedReason = Self.refusalMessage(reason)
            AppLog.error("share refused by admission: \(reason)")
            return false
        }
    }

    private static func refusalMessage(_ reason: AdmissionController.RefuseReason) -> String {
        switch reason {
        case .encodeSessionCap(let max):
            return "Can't share another surface: this Mac's encoder is at capacity (max \(max) concurrent shares)."
        case .uplinkExhausted:
            return "Can't share another surface: your upload bandwidth is fully committed. Unshare something first."
        }
    }

    /// Tear down a share that failed to start or was refused — no dangling capture, context rolled back.
    private func teardownFailedShare(_ windowID: WindowID) async {
        let wasDisplay = localShareKinds[windowID] == .display
        if let capture = localCaptures[windowID] { await capture.stop() }
        localCaptures[windowID] = nil
        localWindowTracks[windowID] = nil
        localShareKinds[windowID] = nil
        localShareScreenTargets[windowID] = nil
        localShareBitrates[windowID] = nil
        await transport.unpublishVideoTrack(for: windowID)
        await pushShareContext(shareContext) // exclude the failed share
        // Defensive: a failed display share must never leave its border/chip up (belt-and-braces —
        // today they're only turned on after admission succeeds, past this path, but keep it robust).
        if wasDisplay {
            borderOverlay.hide()
            isSharingDisplay = shareContext.displayShareCount > 0
        }
    }

    /// Dismiss the admission-refusal alert.
    public func dismissShareRefusal() { shareRefusedReason = nil }

    /// Start sharing a whole display (M11). One display share per sharer in v1 (window+display mix
    /// allowed; a SECOND display is refused with a visible reason — DECISIONS §5.3). The
    /// DisplayCaptureService captures with the hall-of-mirrors filter; naming uses display:<uuid>.
    private func startSharingDisplay(displayID: CGDirectDisplayID) async {
        guard let me = localParticipantID else { return }
        // One-display-per-sharer: refuse a second display (window+display is fine).
        if shareContext.displayShareCount >= 1 {
            shareRefusedReason = "You can share only one screen at a time. Stop the current screen share first."
            return
        }
        // Encode-cap refusal up front (before the codec context flips live tracks → no flicker).
        if let refusal = encodeCapRefusal() { shareRefusedReason = refusal; return }
        // No CGPreflight/CGRequest preflight — it misreports the grant and fires a spurious prompt even
        // when granted (see startSharing). SCStream.startCapture() is the authority; denial is caught below.
        AppLog.info("startSharingDisplay displayID=\(displayID)")

        let windowID = WindowID()
        let capture = DisplayCaptureService(windowID: windowID, displayID: displayID)
        localCaptures[windowID] = capture
        localShareKinds[windowID] = .display
        localShareScreenTargets[windowID] = .display(displayID)

        // Codec-ordering fix + structural D5: a display share forces H.264 for ALL share tracks.
        // Update the context to INCLUDE the pending display BEFORE publish; the transport
        // renegotiates any live VP9 window track to H.264 as part of updateShareContext.
        let pending = shareContext.adding(.display)
        await pushShareContext(pending)

        do {
            let sink = try await transport.publishVideoTrack(for: windowID, kind: .display)
            let events = await capture.events()
            pumps.append(Task { @MainActor [weak self] in
                for await event in events {
                    switch event {
                    case .paused: self?.setLocalPause(windowID, .paused)
                    case .resumed: self?.setLocalPause(windowID, .live)
                    case .ended: self?.unshare(windowID)
                    case .stopped: self?.unshare(windowID)
                    case .resized(let w, let h): self?.updateShareDimensions(windowID, pixelWidth: w, pixelHeight: h)
                    case .frame: break
                    }
                }
            })
            try await capture.start(sink: sink)
            let info = await capture.shareInfo

            if !(await admitShare(windowID: windowID, kind: .display, info: info)) {
                await teardownFailedShare(windowID)
                return
            }

            shareContext = pending
            localWindowTracks[windowID] = await transport.localScreenShareTrack(for: windowID)
            room.addShare(windowID, owner: me)
            sidebarSelection = .screenShares
            if let info { room.setShareInfo(info, window: windowID) }
            // Show the sharer's screen-border affordance.
            borderOverlay.show(displayID: displayID)
            isSharingDisplay = true
            broadcastState()
            broadcastShareEvent(.shared, windowID: windowID, owner: me, info: room.info(of: windowID))
        } catch {
            AppLog.error("startSharingDisplay failed: \(String(describing: error))")
            if isScreenRecordingDenied(error) {
                shareRefusedReason = recoverFromScreenRecordingDenial()
            }
            await teardownFailedShare(windowID)
        }
    }

    /// Whether this instance is currently sharing a display (drives the "Sharing Display" chip).
    public private(set) var isSharingDisplay = false

    /// Stop the current display share (control-bar chip / stop button).
    public func stopDisplayShare() {
        guard let id = localShareKinds.first(where: { $0.value == .display })?.key else { return }
        unshare(id)
    }

    /// Push a share context to the transport (windowCount + wholeDisplay) — the transport's
    /// CodecSelector reads it when building publish options at completePublish (D5).
    private func pushShareContext(_ context: ShareContext) async {
        await transport.updateShareContext(
            windowCount: context.totalShareCount, wholeDisplay: context.wholeDisplay)
    }

    public func unshare(_ windowID: WindowID) {
        Task { await unshareAsync(windowID) }
    }

    private func unshareAsync(_ windowID: WindowID) async {
        // Ownership check for the ROOM/broadcast side. But if we hold LOCAL share bookkeeping for this
        // window (localShareKinds), we ALWAYS tear down our own capture + affordances — even if `room`
        // no longer agrees we own it (a snapshot or reconnect may have dropped it from room state).
        // Otherwise a display share's capture + red border would orphan (the "border still on screen but
        // not sharing" bug). We only skip the room mutation / broadcast when we're not the room owner.
        let weOwnLocally = localShareKinds[windowID] != nil
        let ownsInRoom = localParticipantID != nil && room.owner(of: windowID) == localParticipantID
        guard weOwnLocally || ownsInRoom else { return }
        // Always stop OUR capture + clear OUR bookkeeping (the affordance/orphan fix).
        if let capture = localCaptures[windowID] { await capture.stop() }
        localCaptures[windowID] = nil
        localWindowTracks[windowID] = nil
        let kind = localShareKinds[windowID] ?? .window
        localShareKinds[windowID] = nil
        localShareScreenTargets[windowID] = nil
        localShareBitrates[windowID] = nil
        await transport.unpublishVideoTrack(for: windowID)
        // Update the structural context (removing this share) so any remaining tracks reflect it (a
        // window track may renegotiate VP9↔H.264 as the display share leaves).
        shareContext = shareContext.removing(kind)
        await pushShareContext(shareContext)
        // Display-share teardown: hide the sharer border + clear the chip. ALWAYS, so the red border
        // can't outlive the share even when room state already dropped it.
        if kind == .display {
            borderOverlay.hide()
            isSharingDisplay = shareContext.displayShareCount > 0
        }
        // Room mutation + broadcast only when we're the ROOM owner (skip if room already dropped us).
        if ownsInRoom, let me = localParticipantID {
            room.removeShare(windowID)
            broadcastState()
            broadcastShareEvent(.unshared, windowID: windowID, owner: me)
        }
    }

    private func setLocalPause(_ windowID: WindowID, _ state: RoomModel.PauseState) {
        guard room.owner(of: windowID) == localParticipantID else { return }
        if room.setPauseState(state, window: windowID) { broadcastState() }
    }

    // MARK: - State broadcast

    private func broadcastState() {
        guard let me = localParticipantID, let channel = stateChannel else { return }
        // Include the current ink so a LATE JOINER catches up on annotations in one shot (F9).
        let snap = RoomSnapshot(model: room, draw: drawState.model)
        guard let env = try? WireCodec.pack(snap, sender: me),
              let bytes = try? WireCodec.encode(env) else { return }
        Task { try? await channel.send(bytes) }
    }

    private func broadcastShareEvent(_ action: ShareEvent.Action, windowID: WindowID,
                                     owner: ParticipantID, info: ShareInfo? = nil) {
        guard let channel = stateChannel else { return }
        let ev = ShareEvent(action: action, windowID: windowID, ownerID: owner,
                            revision: room.revision, info: info)
        guard let env = try? WireCodec.pack(ev, sender: owner),
              let bytes = try? WireCodec.encode(env) else { return }
        Task { try? await channel.send(bytes) }
    }

    // MARK: - Shared transcript (D19 — live speech-to-text + recording notes)

    private func startTranscriptPump(_ channel: any WireDataChannel) {
        let incoming = channel.incoming()
        pumps.append(Task { @MainActor [weak self] in
            for await data in incoming {
                self?.applyTranscriptPayload(data)
            }
        })
    }

    /// Apply an inbound `transcript`-channel payload: a TranscriptSegment (merged by segmentID,
    /// final over partial) or a RecordingNoteEvent (note boundary, idempotent last-writer-wins).
    private func applyTranscriptPayload(_ data: Data) {
        guard let envelope = try? WireCodec.decode(data), let kind = envelope.kind else {
            return // unknown/unreadable — skip, never crash
        }
        switch kind {
        case .transcriptSegment:
            guard let seg = try? WireCodec.unpack(envelope, as: TranscriptSegment.self) else { return }
            transcript.apply(seg)
            // The speaker is transcribing THEMSELVES — suppress our local recognition of their
            // audio for the window, so self-published segments win and nothing appears twice.
            lastSelfPublishedSegmentAt[seg.speakerID] = Date().timeIntervalSince1970
        case .recordingNote:
            guard let ev = try? WireCodec.unpack(envelope, as: RecordingNoteEvent.self) else { return }
            transcript.apply(ev)
        default:
            break
        }
    }

    /// One continuous meeting-notes stream: finalized note segments plus live partials, in spoken
    /// order. Single source for the transcript pane and the clipboard export.
    public var meetingNoteSegmentsSorted: [TranscriptSegment] {
        let finalized = transcript.notes.flatMap(\.segments)
        return (finalized + transcript.liveSegments).sorted {
            if $0.startTime == $1.startTime {
                return $0.segmentID.uuidString < $1.segmentID.uuidString
            }
            return $0.startTime < $1.startTime
        }
    }

    /// Whether there is at least one finalized segment worth exporting (partials are excluded).
    public var hasMeetingNotesToCopy: Bool {
        meetingNoteSegmentsSorted.contains(where: \.isFinal)
    }

    /// Copy the meeting notes to the system pasteboard as plain text, one "Name: words" line per
    /// finalized segment. In-flight partials are skipped — they may still be rewritten.
    public func copyMeetingNotesToClipboard() {
        let lines = meetingNoteSegmentsSorted
            .filter(\.isFinal)
            .map { "\(displayLabel(for: $0.speakerID)): \($0.text)" }
        guard !lines.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }

    /// Publish a transcript-channel payload (segments and note events share one send path).
    private func broadcastTranscript<M: WireMessage>(_ payload: M) {
        guard let me = localParticipantID, let channel = transcriptChannel else { return }
        guard let env = try? WireCodec.pack(payload, sender: me),
              let bytes = try? WireCodec.encode(env) else { return }
        Task { try? await channel.send(bytes) }
    }

    /// Toggle transcription (D19 multiplayer dictation). Opt-in. When ON, this Mac transcribes the
    /// LOCAL mic (broadcast to everyone) AND every remote speaker's audio (local-only, per-speaker
    /// attributed), so the whole room appears tagged — `Joe: hello / Henry: hi` — even if nobody
    /// else enables it. Failures stay soft per pipeline.
    public func toggleTranscription() {
        if transcriptionEnabled {
            stopTranscription()
        } else {
            startTranscription()
        }
    }

    private func startTranscription() {
        guard let me = localParticipantID else { return }
        transcriptionEnabled = true
        // A fresh note starts automatically when transcription begins (unless one is already open).
        if transcript.currentNote == nil { startNewNote() }
        transcriptionService.localAudioTrack = { [weak self] in
            await self?.transport.localMicAudioTrack()
        }
        transcriptionService.onSegment = { [weak self] segmentID, text, startTime, isFinal in
            guard let self, let noteID = self.transcript.currentNote?.noteID else { return }
            // Muted mic → no transcription of it. The track delivers no buffers while muted, but a
            // final can straddle the mute moment — gate emission on the effective state too.
            guard self.micLive else { return }
            let seg = TranscriptSegment(segmentID: segmentID, noteID: noteID, speakerID: me,
                                        text: text, startTime: startTime, isFinal: isFinal)
            self.transcript.apply(seg)
            self.broadcastTranscript(seg)
        }
        transcriptionService.start()

        // Remote speakers: per-track local recognition, suppressed for anyone self-publishing.
        remoteTranscription.isSuppressed = { [weak self] speaker in
            self?.isSelfPublishingTranscript(speaker) ?? false
        }
        remoteTranscription.onSegment = { [weak self] speaker, segmentID, text, startTime, isFinal in
            guard let self, let noteID = self.transcript.currentNote?.noteID else { return }
            let seg = TranscriptSegment(segmentID: segmentID, noteID: noteID, speakerID: speaker,
                                        text: text, startTime: startTime, isFinal: isFinal)
            // LOCAL-ONLY — never broadcast (every listener could recognize the same audio; the
            // speaker's own broadcast segments are the shared source of truth when they exist).
            self.transcript.apply(seg)
        }
        // Speech authorization gates BOTH pipelines; await it once here so the remote manager never
        // spins up streams that are doomed to fail (and re-fail every poll tick) while denied.
        Task { @MainActor [weak self] in
            guard await TranscriptionService.requestSpeechAuthorization() == .authorized else { return }
            guard let self, self.transcriptionEnabled else { return } // toggled off mid-prompt
            self.remoteTranscription.start(transport: self.transport)
        }
    }

    private func stopTranscription() {
        transcriptionEnabled = false
        transcriptionService.stop()
        remoteTranscription.stop()
    }

    /// Whether `speaker` has self-published a transcript segment recently (their own transcription
    /// is running) — our local recognition of them yields for the suppression window.
    private func isSelfPublishingTranscript(_ speaker: ParticipantID) -> Bool {
        guard let t = lastSelfPublishedSegmentAt[speaker] else { return false }
        return Date().timeIntervalSince1970 - t < Self.selfPublishSuppressionWindow
    }

    /// Finalize the current recording note and open a fresh one. ANY participant can do this; the
    /// boundary events broadcast, so every client converges on the same notes list.
    public func stopAndStartNewNote() {
        let now = Date().timeIntervalSince1970
        if let current = transcript.currentNote {
            let stop = RecordingNoteEvent(noteID: current.noteID, action: .stop,
                                          startedAt: current.startedAt, endedAt: now)
            transcript.apply(stop)
            broadcastTranscript(stop)
        }
        startNewNote(at: now)
    }

    private func startNewNote(at now: TimeInterval = Date().timeIntervalSince1970) {
        let ev = RecordingNoteEvent(noteID: UUID(), action: .start, startedAt: now)
        transcript.apply(ev)
        broadcastTranscript(ev)
    }

    /// A local share's source window settled at a new size (post-stabilizer). Update the advisory
    /// ShareInfo dimensions in the authoritative room and re-broadcast so receivers re-aspect.
    private func updateShareDimensions(_ windowID: WindowID, pixelWidth: Int, pixelHeight: Int) {
        guard room.owner(of: windowID) == localParticipantID,
              var info = room.info(of: windowID) else { return }
        info.sourcePixelWidth = pixelWidth
        info.sourcePixelHeight = pixelHeight
        if room.setShareInfo(info, window: windowID) { broadcastState() }
    }

    // MARK: - Roster helpers

    public var sharedWindowsSorted: [SharedWindowEntry] {
        room.shares
            .map { SharedWindowEntry(window: $0.key, owner: $0.value) }
            .sorted { $0.window.uuidString < $1.window.uuidString }
    }

    public struct SharedWindowEntry: Equatable {
        public let window: WindowID
        public let owner: ParticipantID
    }

    public func color(for id: ParticipantID) -> Color {
        Color(nsColor: participantSystemColor(for: id))
    }

    /// Apple's semantic system colors adapt to appearance and accessibility settings. The first 12
    /// participants each receive a distinct base color; larger sessions get distinct light/dark
    /// variants derived from the same system palette.
    private static let participantSystemColorPalette: [NSColor] = [
        .systemBlue, .systemOrange, .systemGreen, .systemPink,
        .systemPurple, .systemTeal, .systemRed, .systemCyan,
        .systemYellow, .systemMint, .systemIndigo, .systemBrown,
    ]

    private func participantColorSlot(for id: ParticipantID) -> Int {
        if let slot = participantColorSlots[id] { return slot }
        let count = Self.participantSystemColorPalette.count
        let preferred = ParticipantColor.hueIndex(for: id) % count
        let used = Set(participantColorSlots.values)
        var probe = 0
        var candidate = preferred
        while used.contains(candidate) {
            probe += 1
            let paletteIndex = (preferred + probe) % count
            let variant = probe / count
            candidate = variant * count + paletteIndex
        }
        participantColorSlots[id] = candidate
        return candidate
    }

    private func participantSystemColor(for id: ParticipantID) -> NSColor {
        let slot = participantColorSlot(for: id)
        let palette = Self.participantSystemColorPalette
        let base = palette[slot % palette.count]
        let variant = slot / palette.count
        guard variant > 0 else { return base }
        let fraction = min(CGFloat(variant) * 0.12, 0.48)
        let target = variant.isMultiple(of: 2) ? NSColor.black : NSColor.white
        return base.blended(withFraction: fraction, of: target) ?? base
    }

    private func participantRGBAColor(for id: ParticipantID) -> RGBAColor {
        let color = participantSystemColor(for: id).usingColorSpace(.deviceRGB)
            ?? participantSystemColor(for: id)
        return RGBAColor(
            r: Double(color.redComponent),
            g: Double(color.greenComponent),
            b: Double(color.blueComponent),
            a: Double(color.alphaComponent))
    }

    public func shortLabel(for id: ParticipantID) -> String {
        String(id.uuidString.prefix(4))
    }

    // MARK: - Display names (M10)

    /// Cached LiveKit `participant.name` per participant (JWT `name` claim). Populated on participant
    /// changes; the reactive per-event push arrives with M10.3's ParticipantMediaState hook.
    public private(set) var displayNames: [ParticipantID: String] = [:]

    /// The best label for a participant: their display name if set, else the 4-char UUID fallback.
    public func displayLabel(for id: ParticipantID) -> String {
        if let name = displayNames[id], !name.isEmpty { return name }
        return shortLabel(for: id)
    }

    /// Refresh the display-name cache for the current participant set from the transport.
    private func refreshDisplayNames() async {
        var names: [ParticipantID: String] = [:]
        for id in transportParticipants {
            if let name = await transport.displayName(for: id) { names[id] = name }
        }
        displayNames = names
    }
}
