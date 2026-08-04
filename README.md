# iAgent Panel

A native Swift/AppKit prototype for a macOS dynamic top-center panel. It starts as a compact top-edge notch and expands into a private Home briefing for today’s Apple Calendar events, local Codex agent tasks, open todos, voice capture, focus sessions, and notes.

Home is the starting view. Its compact daily briefing consolidates Calendar events, live Codex work, and all open todos; each inline update opens its full section.

Calendar data is read through Apple EventKit. The first panel open asks for Calendar access; iAgent observes external Calendar changes immediately, force-reloads EventKit on app start and manual refresh, and uses a 15-second fallback refresh. Invite URLs are detected in the event URL, location, and notes. When EventKit omits a saved virtual-conference URL, iAgent supplements today's events from Calendar's local scripting metadata and caches the result locally. Links appear as an `arrow.up.right` control immediately before the calendar name; a single link opens directly, while multiple links share the same control. If access is denied, the Calendar view links directly to the relevant Privacy & Security setting.

The compact bar shows the next meeting time, with the meeting title available as a hover tooltip so it stays clear of the Mac notch. Ten minutes before a timed event, a red record dot appears immediately beside its time. The same control appears at the trailing edge of the current event in Calendar. Press either dot to start an explicit local meeting session: iAgent captures system audio with ScreenCaptureKit, captures your microphone, mixes both sources onto one synchronized stream, and continuously updates one Markdown transcript under `~/Documents/iAgent Library/Notes`. While recording, the compact bar becomes a live transcript, timer, waveform, and red stop control. Press stop to finalize the last speech results and open that exact note. Raw audio and screen frames are not saved.

The dashboard reads recent root-task metadata from Codex's SQLite state store in read-only mode. It watches the database, WAL, and rollout logs for immediate updates, with a two-second fallback refresh for relative timestamps. Subagents are folded into their parent task instead of taking separate rows. Recent tasks remain at the top and are also grouped under draggable project rows below. Rows show live state, Plan/Goal/Voice modes, and time since the latest update. Encrypted reasoning payloads are never read.

Press Option-V while hovering a task to start native live dictation in that row. Pauses keep the earlier transcript, and the flowing waveform becomes a Return icon when the prompt is ready. Press Enter to open the target task and submit through the actual Codex desktop composer; Escape cancels. The first send asks for Accessibility access so iAgent can focus that composer and deliver the prompt visibly, including as a queued follow-up on an active task. Press Option-V without hovering a task to open voice-note capture instead. Notes use a direct formatting toolbar for bold, italic, underline, strikethrough, links, lists, quotes, code, and checklists, with working image, find/replace, heading, rule, and raw-source tools in the overflow menu. Live mode keeps Markdown delimiters invisible—even around the active caret or selection—while the title-row spinner/check reports automatic local saving. Notes and pages remain plain Markdown under `~/Documents/iAgent Library`, and the right-pinned folder button reveals that library in Finder.

The header's plus button opens compact creation actions for a local note (`Command-N`), a new Codex task (`Command-C`), a focus session (`Command-F`), a standalone meeting recorder (`Command-R`), or a local todo (`Command-T`). The standalone recorder immediately enters the same compact listening mode without requiring a Calendar event. From anywhere on macOS, `Option-N` bypasses that menu and opens a fresh, focused note immediately. New Codex tasks are started through app-server. Todos, due dates, and completion history persist in `~/Documents/iAgent Library/todos.json`; list names persist independently in `~/Documents/iAgent Library/todo-lists.json`. Home and the compact status bar both show the current open-todo count.

## iPhone companion

The native SwiftUI companion is in [`Mobile/iAgentMobile.xcodeproj`](Mobile/iAgentMobile.xcodeproj). It uses the panel's same black canvas, compact flat rows, quiet separators, white-opacity hierarchy, and semantic mint/blue/amber/coral status colors. Today consolidates the same briefing; Calendar and Codex are read-only; Notes, Todos, todo lists, and meeting transcripts can be created or edited on either device.

Both apps remain local-first. The Mac's existing Markdown and JSON files stay canonical, while the iPhone keeps its own local sync store and works offline. Changes queue locally and reconcile through the user's private CloudKit database when connectivity returns. Record payloads use CloudKit encrypted fields. Codex activity, event titles/times/links, note contents, todos, and meeting transcripts are therefore copied to the private `iCloud.com.platon.iagent` container when sync is enabled; raw meeting audio is never stored or synced. Concurrent Todo fields merge independently, and concurrent Note-body edits preserve a conflict copy rather than silently replacing text.

To run on an iPhone:

1. Connect and trust the iPhone, then open `Mobile/iAgentMobile.xcodeproj` in Xcode.
2. Select the `iAgentMobile` target and choose an Apple Developer Team under Signing & Capabilities.
3. Register or select the iCloud container `iCloud.com.platon.iagent` with CloudKit enabled for the same team.
4. Select the connected iPhone as the run destination and press Run.

Debug builds launch with local panel-style fixture data by default, so the first device check cannot upload personal content. Pass `--live-sync` only after the fixture pass is verified. Release builds use the real local and CloudKit data path.

After the phone and signing team appear in Xcode, the same preview can be installed from Terminal:

```sh
IAGENT_TEAM_ID=YOUR_TEAM_ID \
  Scripts/install-mobile-preview.sh YOUR_DEVICE_ID
```

To make the later live-sync pass explicit:

```sh
IAGENT_TEAM_ID=YOUR_TEAM_ID \
  IAGENT_LIVE_SYNC=1 \
  Scripts/install-mobile-preview.sh YOUR_DEVICE_ID
```

The command-line simulator build does not require signing:

```sh
xcodebuild -project Mobile/iAgentMobile.xcodeproj \
  -scheme iAgentMobile \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/iagent-mobile-derived \
  CODE_SIGNING_ALLOWED=NO build
```

The ad-hoc-signed Mac build remains fully functional offline. Live CloudKit sync requires the Mac app to be signed with the same Apple Developer Team and iCloud container entitlement.

## Run

```sh
Scripts/run-app.sh
```

This builds and ad-hoc signs `.build/iAgentPanel.app`, preserving a stable bundle identity for macOS permissions. The first use of Option-V asks for microphone and speech-recognition access; the first meeting capture also asks for Screen & System Audio Recording access; the first task submission asks for Accessibility access.

The panel launches at the physical top center of the primary display. Press Option-Space from anywhere on macOS to toggle it; if that shortcut is already owned by another app, iAgent falls back to Control-Option-Space. Press Option-N to jump straight into a new note with the insertion point ready in the editor. You can also scroll over the black notch or click its visible lower edge to expand. Clicking outside an expanded panel preserves the current view in a one-row status header with Calendar, Codex, and todo counts plus the next relevant event time. Click anywhere on that compact header to restore the preserved view; its event time opens Calendar directly. The task list is one continuous scroll surface. Click any row to open that task in Codex, use Up/Down to move the keyboard selection, press Enter to open the selected task, and press Escape or the X button to collapse into the status header.

## Test

```sh
Scripts/build-app.sh
.build/iAgentPanel.app/Contents/MacOS/iAgentPanel --smoke-test
swift test --disable-sandbox
```

The smoke test verifies the compact notch, live status header, preserved-view expansion, and symmetric ramps; renders Home with isolated sample Calendar events; samples panel and number-track animations; loads real root tasks; exercises keyboard navigation, Create shortcuts, and the direct Option-N note route; validates Markdown focus, invisible active markers, empty-caret formatting, literal and multiline underline, checklist selection mapping, saving-to-saved autosave transitions, title inference, find/replace routing, and exact source round-tripping; validates todo history, lists, and due-date persistence; verifies transcript accumulation across a pause; previews the mixed-audio meeting state without requesting capture permissions; verifies stop-to-note routing and in-place Markdown updates; captures visual artifacts; and exits. Real Calendar permission, prompt sending, microphone recognition, and system-audio capture are intentionally left for manual testing.

The note editor vendors an Apache-2.0-licensed fork of [SwiftMarkdownEngine 0.11.0](https://github.com/nodes-app/swift-markdown-engine/tree/0.11.0). The local fork adds strict visual marker hiding, underline, checklist insertion, empty-caret style arming, and the editor command bus used by this app.
