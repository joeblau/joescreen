import AVFoundation
import SwiftUI
import JoeScreenKit
import JoeScreenLiveKit
import LiveKit

/// Native macOS split menu: the main face toggles the microphone and the chevron opens input
/// selection. Keeping this as a Menu lets the window toolbar supply its standard appearance,
/// keyboard behavior, hover treatment, and menu affordance.
struct MicrophoneToolbarMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Section("Microphone") {
                if model.audioInputs.isEmpty {
                    Text("No microphones found")
                } else {
                    ForEach(model.audioInputs) { device in
                        Toggle(isOn: Binding(
                            get: { model.selectedAudioInputID == device.id },
                            set: { isOn in
                                if isOn { model.selectAudioInput(device.id) }
                            }
                        )) {
                            Text(device.name)
                        }
                    }
                }
            }
            Divider()
            // Apple voice processing: echo cancellation + noise suppression + AGC, default ON.
            // It is also what makes the system-level Voice Isolation mic mode available.
            Toggle(isOn: Binding(
                get: { model.voiceIsolationEnabled },
                set: { model.setVoiceIsolation(enabled: $0) }
            )) {
                Label("Voice Isolation", systemImage: "person.wave.2")
            }
            // The system mic-mode picker (Standard / Voice Isolation / Wide Spectrum) — Apple's
            // ML isolation model lives there and is user-selectable only, never app-forced.
            Button {
                AVCaptureDevice.showSystemUserInterface(.microphoneModes)
            } label: {
                Label("Microphone Mode…", systemImage: "waveform.badge.mic")
            }
            Divider()
            Button {
                Task { await model.refreshAudioInputs() }
            } label: {
                Label("Refresh Microphones", systemImage: "arrow.clockwise")
            }
        } label: {
            Label(
                model.micLive ? "Mute Microphone" : "Turn On Microphone",
                systemImage: model.micLive ? "mic.fill" : "mic.slash.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(model.micLive ? Color.primary : Color.red)
        } primaryAction: {
            model.toggleMic()
        }
        .help(model.micLive ? "Mute microphone" : "Turn on microphone")
        .task {
            if model.audioInputs.isEmpty {
                await model.refreshAudioInputs()
            }
        }
    }

}

/// Native camera split menu with the same primary-action/dropdown behavior as the microphone.
struct CameraToolbarMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Section("Camera") {
                if model.videoInputs.isEmpty {
                    Text("No cameras found")
                } else {
                    ForEach(model.videoInputs) { device in
                        // A native menu toggle renders the selected state as a leading checkmark.
                        // Treat these toggles as a radio group: turning one on selects it, while an
                        // attempted off-write for the current camera is ignored.
                        Toggle(isOn: Binding(
                            get: { model.selectedVideoInputID == device.id },
                            set: { isOn in
                                if isOn { model.selectVideoInput(device.id) }
                            }
                        )) {
                            Text(device.name)
                        }
                    }
                }
            }
            Divider()
            Button {
                Task { await model.refreshVideoInputs() }
            } label: {
                Label("Refresh Cameras", systemImage: "arrow.clockwise")
            }
        } label: {
            if model.cameraBusy {
                ProgressView()
                    .controlSize(.small)
                    .help("Starting camera…")
            } else {
                Label(
                    model.cameraEnabled ? "Turn Off Camera" : "Turn On Camera",
                    systemImage: model.cameraEnabled ? "video.fill" : "video.slash.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(model.cameraEnabled ? Color.primary : Color.red)
            }
        } primaryAction: {
            guard !model.cameraBusy else { return }
            model.toggleCamera()
        }
        .help(model.cameraBusy ? "Starting camera…" : (model.cameraEnabled ? "Turn off camera" : "Turn on camera"))
        .task {
            if model.videoInputs.isEmpty {
                await model.refreshVideoInputs()
            }
        }
    }

}

/// Session-scoped clipboard sharing presented as a native stateful toolbar toggle.
struct ClipboardToolbarToggle: View {
    @Environment(AppModel.self) private var model

    private var isOn: Binding<Bool> {
        Binding(
            get: { model.clipboardSyncEnabled },
            set: { model.setClipboardSyncEnabled($0) })
    }

    var body: some View {
        Toggle(isOn: isOn) {
            Label(
                model.clipboardSyncEnabled ? "Stop Clipboard Sharing" : "Share Clipboard",
                systemImage: model.clipboardSyncEnabled ? "doc.on.clipboard.fill" : "doc.on.clipboard")
                .labelStyle(.iconOnly)
        }
        .toggleStyle(.button)
        .help(model.clipboardSyncEnabled
              ? "Clipboard sharing is on — click to stop"
              : "Share clipboard with the room for this session")
    }
}

/// The local webcam self-preview tile (mirrored, like a normal selfie view). Rendered in the shares
/// area while the camera is on. Reuses LiveKit's `SwiftUIVideoView` — the same renderer as remote
/// windows (`RemoteVideoView`), which accepts a local `VideoTrack` directly.
struct SelfPreviewTile: View {
    @Environment(AppModel.self) private var model
    let track: VideoTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.black)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .overlay {
                    VideoSurface(track: track, layoutMode: .fit, mirrorMode: .mirror)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.tint, lineWidth: 3))
            HStack(spacing: 6) {
                Image(systemName: "video.fill")
                    .font(.caption2)
                    .foregroundStyle(.tint)
                Text("You")
                    .font(.caption.monospaced())
                Spacer()
            }
        }
    }
}
