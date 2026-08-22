import SwiftUI
import JoeScreenKit
import JoeScreenUI
import JoeScreenLiveKit
import LiveKit

/// The in-call workspace: participants and notes in the collapsible leading sidebar, shared screens
/// in the center, and face video in the trailing inspector. Remote shared windows are also
/// rendered as separate native NSWindows (M4).
struct SessionView: View {
    @Environment(AppModel.self) private var model
    @State private var isConfirmingLeave = false

    private var inspectorPresentation: Binding<Bool> {
        Binding(
            get: { model.inspectorIsPresented },
            // A system reconciliation hide is intentionally not persisted as user preference.
            set: { model.handleSystemInspectorPresentationChange($0) })
    }

    var body: some View {
        // This is deliberately the session root: NavigationSplitView owns the leading navigator and
        // supplies the standard macOS sidebar toolbar command/keyboard behavior.
        NavigationSplitView {
            SessionSidebar {
                isConfirmingLeave = true
            }
        } detail: {
            SessionDetail()
        }
        // Keep this at the session root so AppKit owns one coherent inspector transition. A custom
        // split item appears abruptly, while a detail-scoped inspector can reflow trailing toolbar
        // items into the overflow menu during its slide-in animation.
        .inspector(isPresented: inspectorPresentation) {
            SessionInspector()
                .inspectorColumnWidth(min: 220, ideal: model.inspectorWidth, max: 380)
        }
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                if model.gateMuted {
                    Label("Microphone yielding", systemImage: "person.2.wave.2.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .help("Mic auto-muted: a co-located participant is speaking")
                }

                if model.isSharingDisplay {
                    Button {
                        model.stopDisplayShare()
                    } label: {
                        Label("Stop Sharing Display", systemImage: "stop.circle.fill")
                    }
                    .help("Stop sharing your screen")
                }
            }

            // This action follows the selected sidebar destination: screen destinations can be
            // shared, while Meeting Notes exposes the transcription + copy-notes controls.
            ToolbarItemGroup(placement: .primaryAction) {
                if model.sidebarSelection == .notes {
                    Button {
                        model.copyMeetingNotesToClipboard()
                    } label: {
                        Label("Copy Notes", systemImage: "doc.on.doc")
                    }
                    .disabled(!model.hasMeetingNotesToCopy)
                    .help("Copy the meeting notes to the clipboard")

                    Button {
                        model.toggleTranscription()
                    } label: {
                        Label(
                            model.transcriptionEnabled ? "Stop Transcribing" : "Transcribe",
                            systemImage: model.transcriptionEnabled
                                ? "waveform.circle.fill"
                                : "waveform.circle")
                    }
                    .help(model.transcriptionEnabled
                          ? "Stop transcribing the call"
                          : "Transcribe the call on this Mac")
                } else {
                    // Ephemeral annotation (F9.1): the pencil arms draw mode over the share grid.
                    // Strokes broadcast to everyone and evaporate 15s after each stroke ends.
                    Button {
                        model.toggleDrawMode()
                    } label: {
                        Label("Annotate",
                              systemImage: model.drawState.drawModeEnabled
                                  ? "pencil.tip.crop.circle.fill"
                                  : "pencil.tip.crop.circle")
                            .foregroundStyle(model.drawState.drawModeEnabled
                                             ? AnyShapeStyle(Color.accentColor)
                                             : AnyShapeStyle(.primary))
                    }
                    .help(model.drawState.drawModeEnabled
                          ? "Stop annotating shared screens"
                          : "Draw on shared screens — ink fades after 15 seconds")

                    Button {
                        model.beginShare()
                    } label: {
                        Label("Share", systemImage: "plus.rectangle.on.rectangle")
                    }
                    .help("Share a window or your whole screen with the room")
                }
            }

            ToolbarItemGroup(placement: .principal) {
                MicrophoneToolbarMenu()
                CameraToolbarMenu()
                ClipboardToolbarToggle()

                Button {
                    model.setActiveSpeakerPictureInPicturePresented(
                        !model.isActiveSpeakerPictureInPicturePresented)
                } label: {
                    Label(
                        "Active Speaker Picture in Picture",
                        systemImage: model.isActiveSpeakerPictureInPicturePresented ? "pip.exit" : "pip.enter")
                }
                .help(model.isActiveSpeakerPictureInPicturePresented
                      ? "Close active-speaker picture in picture"
                      : "Show active speaker in picture in picture")
            }

            // Keep the inspector at the far primary-action edge, but outside the contextual action
            // capsule. On Liquid Glass, a fixed toolbar spacer is required to break adjacent items
            // with the same placement into distinct visual groups.
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    // Inspector owns its platform transition.
                    model.toggleInspector()
                } label: {
                    Label("Toggle Inspector", systemImage: "sidebar.trailing")
                }
                .help(model.inspectorIsPresented ? "Hide participant faces" : "Show participant faces")
            }
        }
        .alert("Leave this session?", isPresented: $isConfirmingLeave) {
            Button("Cancel", role: .cancel) {}
            Button("Leave", role: .destructive) {
                model.leave()
            }
        } message: {
            Text("Your microphone, camera, and active screen shares will be disconnected.")
        }
        // Admission refusal (M11): a visible alert when a share won't fit the uplink / encode budget.
        .alert("Can't share", isPresented: Binding(
            get: { model.shareRefusedReason != nil },
            set: { if !$0 { model.dismissShareRefusal() } })) {
            Button("OK", role: .cancel) { model.dismissShareRefusal() }
        } message: {
            Text(model.shareRefusedReason ?? "")
        }
        // Remote-control consent (F4): the owner approves/denies a peer's request to drive a window.
        .alert("Allow remote control?", isPresented: Binding(
            get: { model.pendingControlRequest != nil },
            set: { if !$0 { model.denyControlRequest() } })) {
            Button("Allow") { model.approveControlRequest() }
            Button("Deny", role: .cancel) { model.denyControlRequest() }
        } message: {
            if let req = model.pendingControlRequest {
                Text("\(model.displayLabel(for: req.participantID)) wants to control your shared window.")
            }
        }
    }
}

/// The selected navigator destination projected into the center column. Status/control chrome uses
/// safe-area insets so it does not participate in navigation or scroll content.
private struct SessionDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.sidebarSelection {
            case .screenShares:
                SharesPane()
            case .notes:
                TranscriptPane()
            case .participant(let participantID):
                SharesPane(ownerFilter: participantID)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            RemoteControlBanner()
        }
        // Constant min/max frame on every split-column root (also sidebar + inspector): on macOS 26
        // AppKit throws NSInternalInconsistencyException if a column's NSHostingView reports a
        // CHANGED min/max size during the window's constraint-update pass, which width-dependent
        // content (wrapping text, adaptive grids) otherwise does on live resize → crash
        // (SplitViewChildController.hostingView(_:didUpdateMinSize:maxSize:) mid-display-cycle).
        .frame(minWidth: 360, maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
        .navigationTitle(model.joinParameters?.room ?? "JoeScreen")
    }
}

/// Native trailing utility inspector dedicated to participant faces.
private struct SessionInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ParticipantFaceColumn(selectedParticipantID: model.selectedParticipantID)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                model.recordInspectorWidth(Double(width))
            }
            // Same macOS 26 resize-crash guard as SessionDetail: the reported min/max size of this
            // column's hosting view must stay constant through a live-resize constraint pass. Min
            // width matches the `inspectorColumnWidth` floor at the session root.
            .frame(minWidth: 220, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
    }
}

/// The remote-control status banner (F4): "X is driving" while a peer controls one of your windows,
/// plus the R8 secure-input notice when secure input is blocking injection.
struct RemoteControlBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let driver = model.activeDriverLabel {
                banner("\(driver) is controlling your screen", systemImage: "hand.point.up.left.fill", tint: .blue)
            }
            if model.secureInputBanner == .secureInputBlocking {
                banner("This field can't be remote-controlled (secure input is active).",
                       systemImage: "lock.fill", tint: .orange)
            }
        }
    }

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.caption.weight(.medium))
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(tint.opacity(0.12))
    }
}

/// The list of windows currently shared in the room (owner-color labeled). M4 populates this from
/// the mirrored RoomModel and opens/moves the corresponding native windows.
struct SharesPane: View {
    @Environment(AppModel.self) private var model
    var ownerFilter: ParticipantID?

    init(ownerFilter: ParticipantID? = nil) {
        self.ownerFilter = ownerFilter
    }

    var body: some View {
        let shared = model.sharedWindowsSorted.filter { ownerFilter == nil || $0.owner == ownerFilter }
        VStack(spacing: 0) {
            // Camera previews live in the face inspector, so the center remains dedicated to the
            // room's shared screens.
            if shared.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: "rectangle.dashed")
                } description: {
                    Text(emptyMessage)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(shared, id: \.window) { entry in
                            SharedWindowTile(windowID: entry.window, ownerID: entry.owner)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private var emptyTitle: String {
        ownerFilter == nil ? "No screens shared yet" : "No shares from this participant"
    }

    private var emptyMessage: String {
        if ownerFilter != nil { return "Choose Screen Shares to see everything in the room." }
        return "Click Share to share a window or screen,\nor wait for someone else to share."
    }
}

/// A tile representing one shared window in the grid. Shows owner-color chrome, pause state, and a
/// state-aware action: **Focus** raises the native viewer window; **Reopen** re-subscribes a window
/// the user closed (M9). The placeholder glyph is the thumbnail until M10 upgrades it to live video.
struct SharedWindowTile: View {
    @Environment(AppModel.self) private var model
    let windowID: WindowID
    let ownerID: ParticipantID

    private var isLocal: Bool { model.isLocallyOwnedShare(windowID) }
    private var isClosed: Bool { model.isRemoteWindowClosed(windowID) }
    private var isRendering: Bool { model.isRemoteWindowRenderingActive(windowID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .aspectRatio(16.0/10.0, contentMode: .fit)
                .overlay {
                    // Live mini-thumbnail. For a REMOTE share: a SECOND SwiftUIVideoView on the already-
                    // held remote track (one decode, two renderers; the big window keeps its quality).
                    // Gated on the window RENDERING (not just open): a soft-hidden window detaches its big
                    // renderer so adaptive-stream stops SFU forwarding — the thumbnail must detach its
                    // renderer too, or the second renderer keeps the stream flowing and defeats R24/R32.
                    // For OUR OWN share: you never subscribe to your own publications, so there's no
                    // remote track — render the LOCAL published track instead so the sharer sees a live
                    // self-preview (previously this fell through to the placeholder glyph — the bug).
                    if isLocal, let track = model.localWindowTrack(windowID) {
                        SwiftUIVideoView(track, layoutMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if !isClosed, isRendering, let track = model.remoteWindowTrack(windowID) {
                        SwiftUIVideoView(track, layoutMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: isClosed ? "macwindow.badge.plus" : "macwindow")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(model.color(for: ownerID), lineWidth: 3))
                // Ephemeral annotation ink (F9.1): every tile RENDERS everyone's strokes (the
                // sharer sees ink land on their own preview), but drawing is captured only over
                // OTHER participants' shares. The replicated ShareInfo aspect keeps normalized
                // stroke coordinates on the same pixel feature at every peer.
                .overlay {
                    GeometryReader { geo in
                        DrawOverlay(windowID: windowID, size: geo.size,
                                    videoAspect: model.room.shareInfo[windowID]?.sourceAspectRatio
                                        ?? model.remoteWindowAspect(windowID))
                            .allowsHitTesting(!isLocal)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .onTapGesture { if !isLocal { focusOrReopen() } }
            HStack(spacing: 6) {
                Circle().fill(model.color(for: ownerID)).frame(width: 8, height: 8)
                Text(model.displayLabel(for: ownerID))
                    .font(.caption.monospaced())
                if model.room.pauseState(of: windowID) == .paused {
                    Text("paused").font(.caption2).foregroundStyle(.orange)
                }
                if isLocal { Text("sharing").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                // Local share: stop it. Remote share: focus its viewer window (or reopen if closed).
                if isLocal {
                    Button("Stop") { model.unshare(windowID) }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                } else {
                    Button(isClosed ? "Reopen" : "Focus") { focusOrReopen() }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                }
            }
        }
    }

    private func focusOrReopen() {
        if isClosed { model.reopenRemoteWindow(windowID) }
        else { model.focusRemoteWindow(windowID) }
    }
}
