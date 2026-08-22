// Version history for the download page's "What's new" section. Inlined (no runtime fetch / no build
// step) to match the worker's asset-free philosophy. Keep in sync with the repo's /CHANGELOG.md when
// cutting a release: bump `APP_VERSION` in wrangler.jsonc AND prepend a release here.

export interface Release {
	version: string;
	date: string; // ISO yyyy-mm-dd
	/** Optional tag shown next to the version (e.g. "early beta"). */
	tag?: string;
	/** Short user-facing highlights (the page shows these; full notes live in CHANGELOG.md). */
	highlights: string[];
}

// Newest first.
export const RELEASES: Release[] = [
	{
		version: "0.5.1",
		date: "2026-08-22",
		tag: "early beta",
		highlights: [
			"Much lower CPU while in a call — video surfaces now render only when a new frame actually arrives, instead of re-rendering 60 times a second, and the app stopped doing busywork while idle in a call",
			"Fixed a crash when resizing the session window on the macOS 26 beta",
		],
	},
	{
		version: "0.5.0",
		date: "2026-08-21",
		tag: "early beta",
		highlights: [
			"Voice isolation is on by default and now has an off switch — echo cancellation, noise suppression, and auto gain live in the mic menu, alongside a shortcut to the system Microphone Mode picker",
			"When someone draws on your shared window, you now see their ink on the real window — and it never gets baked into the video everyone else receives",
			"Join sheet and roster refinements",
		],
	},
	{
		version: "0.4.0",
		date: "2026-08-21",
		tag: "early beta",
		highlights: [
			"Ephemeral screen annotations: arm the pencil and draw on anyone's shared screen — ink shows for the whole room and fades 15 seconds after each stroke",
			"Native toolbar rework: mic, camera, and clipboard moved into toolbar menus; the inspector toggle gets its own capsule",
			"Meeting notes now read top-down and auto-follow new lines, with a new Copy Notes action",
			"Polished join sheet, native empty states for shares and notes, and a more compact minimum window size",
		],
	},
	{
		version: "0.3.2",
		date: "2026-08-13",
		tag: "early beta",
		highlights: [
			"Shared windows now carry their owner's name — window titles, share tiles, and the Focus menu all say whose window it is",
			"iOS beta: calls keep running in the background, Picture-in-Picture, and clean call-end handling",
			"Fix: the app now reports its real version — every earlier build claimed 0.1.0 in About and Finder",
		],
	},
	{
		version: "0.3.1",
		date: "2026-08-07",
		tag: "early beta",
		highlights: [
			"Fix: transcription produced no text in 0.3.0 (recognizer ignored the call's Int16 audio, and results only flush at utterance boundaries — both fixed)",
			"Captions now appear per utterance, ~1 second after each speaker pauses",
		],
	},
	{
		version: "0.3.0",
		date: "2026-08-07",
		tag: "early beta",
		highlights: [
			"Multiplayer dictation: one person enables Transcribe and the whole call is captioned, every line tagged with the speaker's name",
			"Speakers who also transcribe publish their own captions, which take precedence automatically",
			"Fix: local mic transcription produced no text (now taps the call's echo-cancelled capture; muted mics are never transcribed)",
			"Fix: transcription no longer gives up after quiet stretches",
		],
	},
	{
		version: "0.2.1",
		date: "2026-08-07",
		tag: "early beta",
		highlights: [
			"Fix: enabling Transcribe crashed the app for first-time users (Speech permission callback)",
			"Transcription now fails soft (with a visible reason) when no usable microphone input exists",
		],
	},
	{
		version: "0.2.0",
		date: "2026-08-06",
		tag: "early beta",
		highlights: [
			"Shared live transcript + recording notes — on-device speech-to-text, merged per speaker",
			"Co-located audio: mark same-room participants and your mic auto-yields (no doubled voices)",
			"⌘⇧M global mute hotkey + Call menu; mic state always matches what the room hears",
			"Share list stays in sync with simultaneous sharers; late joiners see every live share",
			"Screen Recording permission fixes: no re-prompts, auto-recovery after app updates",
			"Live self-preview of your own shared window",
		],
	},
	{
		version: "0.1.0",
		date: "2026-07-10",
		tag: "early beta",
		highlights: [
			"Everyone's webcam in tiles — names, mic + speaking indicators",
			"Share a window or your whole screen as movable native windows",
			"Draw, annotate, and cross-user clipboard on shared windows",
			"Rooms + invite links that unfurl in Slack/iMessage",
			"Menu-bar residency with recent sessions",
			"Reliable shares: no frozen ghost windows, cursors aligned per-pixel",
		],
	},
];

/** The current (newest) version string, used for the download badge. */
export const CURRENT_VERSION = RELEASES[0]?.version ?? "0.1.0";
