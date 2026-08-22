# Changelog

All notable changes to JoeScreen (macOS). JoeScreen is in **early beta**. Format based on
[Keep a Changelog](https://keepachangelog.com); this project uses [Semantic Versioning](https://semver.org).

The user-facing highlights from each version are also shown in the "What's new" section of
[joescreen.cheffing.dev](https://joescreen.cheffing.dev) — keep that section (in
`apps/joescreen-download/src/changelog.ts`) in sync with the entries here when you cut a release.

## [0.5.0] — 2026-08-21 · early beta

### New
- **Voice isolation, on by default with a way to turn it off** — echo cancellation, noise
  suppression, and automatic gain are now a persisted preference rather than something the app
  forces on. The mic menu gains a **Voice Isolation** toggle and a **Microphone Mode…** item that
  opens the system picker (Apple's ML isolation mode can only be chosen by you, never set by an
  app). The preference is applied after connect and before the first mic enable, so capture starts
  in the right state.
- **The sharer now sees remote ink on the real window** — when a peer annotates your shared window,
  the strokes are painted on borderless click-through overlay windows floating exactly over the
  window or display you're sharing, using the same geometry viewers see. The overlays are excluded
  from the capture filter, so ink is never baked into the outgoing video.

### Changed
- Join-sheet and roster refinements.

### Internal
- Ultrasonic pairing spike under `Spikes/UltrasonicPairingSpike/`, camera integration test
  coverage, and `app.sh` dev-loop tweaks.

[0.5.0]: https://joescreen.cheffing.dev

## [0.4.0] — 2026-08-21 · early beta

### New
- **Ephemeral screen annotations** — the pencil in the All Screens toolbar arms draw mode; strokes
  drawn over any other participant's share tile broadcast to the whole room and evaporate 15
  seconds after each stroke ends. Expiry is scheduled on every ingest path (your own strokes,
  inbound strokes, and the snapshot a late joiner receives), and it preserves the per-author
  sequence watermark so replayed expired strokes stay rejected.
- **Copy Notes** — a transcript toolbar action that exports the finalized meeting notes as plain
  text.

### Changed
- **Native toolbar rework** — mic, camera, and clipboard controls moved out of the bottom media bar
  into native toolbar split menus. The inspector toggle now sits in its own Liquid Glass capsule on
  macOS 26 (gated; the deployment floor stays macOS 14).
- **Inspector** — visibility is a single global preference instead of being remembered per sidebar
  selection, and it attaches to the split view, so opening it no longer flashes the `>>` toolbar
  overflow chevron.
- **Transcript** — meeting notes read top-down and auto-follow new lines as they arrive.
- **Join sheet** — the form hugs its content, rows are uniform height, and the valid-URL check icon
  is gone.
- Empty share and note lists use native `ContentUnavailableView`s, the window minimum is a more
  compact 880×520, and participant tiles and the roster got display-name polish.

[0.4.0]: https://joescreen.cheffing.dev

## [0.3.2] — 2026-08-13 · early beta

### Changed
- Shared windows now carry their owner's name everywhere one appears: window titles, share
  tiles, and the Focus menu all say whose window it is.

### iOS beta
- Calls keep running when the app is backgrounded, Picture-in-Picture for shared windows, and
  call end is handled cleanly (no stuck sessions).

### Fixed
- **The app now reports its real version** — the generated Info.plist hardcoded
  `CFBundleShortVersionString` to 0.1.0, so every earlier build (macOS and iOS) claimed 0.1.0 in
  About, Finder, and crash reports regardless of the actual release.

## [0.3.1] — 2026-08-07 · early beta

### Fixed
- **Transcription produced no text in 0.3.0** — two independent breakers, both fixed:
  1. Call audio arrives as Int16 PCM, which Apple's speech recognizer silently ignores (no text,
     no error). All recognition audio is now converted to Float32.
  2. Apple's buffer-based recognition delivers NO results — not even partials — until the audio
     stream is explicitly ended. Live calls never end their audio, so nothing could ever appear.
     Transcription now segments utterances with a lightweight energy gate: ~1 s of trailing
     silence (or 12 s of continuous speech) flushes the recognizer and text appears per utterance.
- Field diagnostics: a 5 s input-level heartbeat in the logs, and env-gated capture of the exact
  audio fed to the recognizer (`JOESCREEN_DUMP_SPEECH_AUDIO=1`).

[0.3.1]: https://joescreen.cheffing.dev

## [0.3.0] — 2026-08-07 · early beta

### New
- **Multiplayer dictation** — one person enabling Transcribe now captions the WHOLE call on their
  Mac: every remote speaker's audio is transcribed locally (one recognizer per participant track,
  so attribution is structural) and every line is tagged with the speaker's name — `Joe: hello /
  Jeevan: hi / Henry: hello`. Speakers who also enable Transcribe publish their own captions
  (better audio, their consent), which automatically take precedence — nothing appears twice.

### Fixed
- **Local mic transcription produced no text at all** — the dedicated audio engine it used receives
  only silence while the call's voice processing owns the microphone. Transcription now taps the
  call's own echo-cancelled capture, which also guarantees a muted mic is never transcribed.
- **Transcription no longer dies after quiet stretches** — the recognizer's routine "no speech
  detected" end-of-utterance was treated as a fatal failure ("Speech recognition repeatedly
  failed"); it now just rolls a fresh recognition task.

[0.3.0]: https://joescreen.cheffing.dev

## [0.2.1] — 2026-08-07 · early beta

### Fixed
- **Crash when enabling transcription** — tapping Transcribe crashed the app for anyone who hadn't
  previously granted Speech Recognition permission: the Speech framework's authorization (and
  recognition) callbacks fire on their own system queues, but inherited the service's main-actor
  isolation, tripping the Swift 6 runtime's executor assertion (SIGTRAP). All Speech/audio-tap
  callbacks are now explicitly `@Sendable`, and an invalid microphone input format now fails soft
  (transcription unavailable) instead of raising an uncatchable exception.

[0.2.1]: https://joescreen.cheffing.dev

## [0.2.0] — 2026-08-06 · early beta

Live transcripts, smarter same-room audio, and a big batch of sharing/permission fixes. Also the
first cycle where the iOS companion (TestFlight) can share its camera and whole screen.

### New
- **Shared live transcript + recording notes** — everyone's speech, transcribed on each person's own
  Mac (Apple Speech, on-device when supported) and merged into one speaker-attributed live
  transcript in the new Notes pane. Anyone can cut a recording note; the notes list stays in sync
  for the whole room. Opt-in per person; nothing but text ever leaves your machine.
- **Co-located audio mitigation** — mark a participant as co-located (same physical room) from the
  roster; your mic automatically yields while they're the dominant speaker and releases when they
  go quiet or you clearly take over. No more doubled voices from two laptops in one room.
- **Mute from anywhere** — ⌘⇧M toggles your mic globally (plus a Call menu with the same shortcut),
  and the mic button/menus now always reflect what the room actually hears.
- **Live self-preview** for your own shared window in the shares pane (was a placeholder).
- **iOS (TestFlight):** share your camera, toggle mic/camera, and share your whole screen via the
  system broadcast picker.

### Fixed
- **Share list stays in sync**: shares from two people sharing at once no longer vanish from the
  list, late joiners now see every already-live share (video *and* list entry), and phantom
  participants no longer appear in the roster.
- **Late-join video reliability**: a track that was already live when you joined could stay
  invisible until re-shared (LiveKit join race) — now recovered automatically with bounded retries.
- A newcomer's mic/camera no longer shows muted/off to peers until they toggle.
- The sharer's red border now covers the correct region on multi-display setups, and an orphaned
  border/"Sharing Display" pill can no longer outlive the share after a retry/desync.
- Screen Recording: no more re-prompt on every share when already granted, and automatic recovery
  from a stale grant after an app update.
- No more spurious "Couldn't join" when a single track renegotiation timed out mid-call.
- The system share picker no longer lingers on screen after you pick a window/screen.
- Release builds: mic/camera were blocked by missing device entitlements.

### Under the hood
- Explicit echo-cancellation/auto-gain/noise-suppression capture configuration (VoiceProcessingIO
  pinned on macOS).
- Room-state sync moved from revision-gated snapshot replace to per-window union merge with ordered
  share events (fixes concurrent-sharer collisions by design; D20).

[0.2.0]: https://joescreen.cheffing.dev

## [0.1.0] — 2026-07-10 · early beta

The first public build. Everyone's webcam in tiles, share a window _or_ your whole screen, and every
remote share is a real, movable native window on your desktop — plus a wide collaboration toolset.

### Screen sharing
- **Share a window _or_ your whole screen** — shared surfaces open as movable, aspect-true windows on
  every desktop (not a screenshare rectangle). Multiple simultaneous shares supported.
- **Live share thumbnails** in the shares pane — tap to bring a shared window to the front.
- **Reliable windows** — a crashed/disconnected sharer's window closes cleanly (no frozen "ghosts");
  windows resize with their source, reopen at their remembered spot, and never open off-screen.
- **Password-manager windows are never shareable** (1Password, Bitwarden, Keychain, …).

### See everyone
- **Participant webcam tiles** — everyone live, or an avatar when their camera is off, with names,
  mic-muted badges, and a green speaking ring.
- **Display names** — set "Your name" on join; peers (and late joiners) see it everywhere.
- **Multiplayer cursors** — see everyone's pointer, per window, aligned to the exact pixel at both ends.

### Collaborate
- **Draw / annotate** on any shared window — live ink in each author's color, with per-author undo/clear.
- **Cross-user clipboard** — opt in per session (off by default, never persisted).
- **Remote control groundwork** — click and type into a shared window (owner grants control; ships off
  by default pending the accessibility grant).
- **Rooms + invite links** — shareable links that unfurl in Slack/iMessage, a browser view-only "watch"
  page, and live presence.

### Voice & app
- **Built-in voice** on the same live connection; self camera preview + device pickers; **Join muted**
  preference.
- **Menu-bar residency** — quick mic/share/leave and a Recent-sessions list from the menu bar.
- Join via a launch argument, a `joescreen://` deep link, or the join sheet.
- Notarized Developer-ID `.dmg` for direct download (macOS 14+, Apple Silicon &amp; Intel).

### Under the hood
- Whole-screen and multi-window shares use H.264 for reliability; a single window stays VP9 for crisp
  small text — adding a screen share transparently renegotiates existing shares.
- Upload-bandwidth admission is enforced: a share that won't fit is refused with a clear reason rather
  than silently degrading everyone.

[0.1.0]: https://joescreen.cheffing.dev
