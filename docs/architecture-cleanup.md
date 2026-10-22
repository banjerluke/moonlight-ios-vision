# Architecture cleanup — working plan

Orchestrated from bb thread `thr_iytp52gqzi`. Integration branch: `bb/identify-high-impact-codebase-improvements-thr_iytp52gqzi` (based on `vision-testflight` @ `fb34983`). Child threads branch from it; the orchestrator merges them back and updates this file. Children: don't edit this file — put notes in your final report instead.

Goal: fix the confirmed crash/leak bugs, delete dead weight, then pull the stream lifecycle into one deep module (`StreamSession`) and settings keys into one registry. Behaviour should stay the same apart from the bugs being fixed.

## Ground rules for every ticket

- **Setup.** A fresh worktree has no submodules: `git submodule update --init --recursive`.
- **Build check.** HEAD does not link from a clean checkout. `fb34983` removed `libswresample`, and the build has no `-lz`/`-liconv`; the simulator libs are device builds. So the gate is *compile-clean*: the build must show no errors besides that known link failure.
  ```sh
  xcodebuild -project Moonlight.xcodeproj -scheme "Moonlight XrOS" -destination 'generic/platform=visionOS' \
    -derivedDataPath /tmp/mlv-build/$BB_THREAD_ID CODE_SIGNING_ALLOWED=NO build > /tmp/mlv-build/$BB_THREAD_ID.log 2>&1
  rg ' error:' /tmp/mlv-build/$BB_THREAD_ID.log | rg -v 'linker command failed'   # must print nothing
  ```
  The iOS and tvOS targets were already broken at `fb34983`: deployment target 12.0, shared code calling the Vision-only `MainViewModel`, and `moonlight-common-tv` without OpenSSL. Don't gate on them. Do keep any `TARGET_OS_*` guards you see in `Limelight/` intact.
- **Testing.** No test target exists, and the simulator can't link, so there are no runnable tests. Don't add a test target. Mark anything that needs on-device checking in your report.
- **Commits.** Make small, focused commits on your own branch, one logical fix each. End each message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Don't push, and don't open PRs.
- **Scope.** Stay inside your ticket's files. If a fix needs a file another ticket owns, note it in your report instead of editing it.
- **Line numbers.** The line numbers below are from `fb34983`. Re-read the code before you change anything, because the audit could be wrong. If a "bug" turns out not to be one, say so and skip it.

## Wave 1 — parallel, disjoint files

### A. Decoder correctness — `Moonlight Vision/DrawableVideoDecoder.swift`
Owns that file. It may make a minimal edit at the call site in `RealityKitStreamView.swift:2425-2440`, where the decoder callbacks are wired.
1. On every IDR, a new `VTDecompressionSession` is created (:789) without invalidating the old one. Wait for async frames and invalidate the previous session first.
2. `parameterSetBuffers` (:762) is never cleared between IDRs. Clear it after the format description is built, the way `VideoDecoderRenderer.m:475,514` does.
3. `UnsafePointer<UInt8>(parameterSetBuffers[index])` (:857 and the HEVC twin) dangles. Keep the buffers pinned while the `CMVideoFormatDescriptionCreateFrom…` call runs.
4. `setHdrMode` (:1200-1230) clears metadata and requests an IDR when the metadata hasn't changed. Fix both branches.
5. `stop()` races the decode callback:
   - pipeline states are force-unwrapped on the VT thread (:430, :449)
   - the callback context is `passUnretained(self)` (:191)
   - there is no `VTDecompressionSessionWaitForAsynchronousFrames`
   Make shutdown safe, using a lock or serial queue plus locals.
6. Add a real render gate inside the decoder: an atomic "rendering enabled" flag checked per frame. Today's `renderGateOpen` in `RealityKitStreamView` is checked only once, at setup (:2435). Expose the gate so the view's teardown can close it.
7. `enableAmbilightProvider` reads `@MainActor` `streamSettings` from the VT thread on every frame (RK :2431). Pass a thread-safe snapshot instead; see `ThreadSafeHDRSettings` in `InputCaptureUIView.swift:18` for the pattern.
8. Per-frame waste:
   - `updateHDRMetadata()` fills `hdrMetadata`, which nothing reads (:330)
   - the 20-case pixel-format switch runs twice per frame (:231-257, :453-479); classify once per format change
   - delete the unused fields `texture`, `outTexture`, `region`, `imagePlaneVertexBuffer`, `streamAspectRatio` and `copyPipelineFormat`, after confirming they're unused
9. Leave as-is and only report: `generateMipmaps` runs every frame (:514). It may be the anti-shimmer measure, so don't touch it (see ticket G). Also report on `DispatchQueue.main.sync` in `setupLowLevelTexture` (:582): is it a real deadlock risk, and what would a fix look like?

### B. Connection, audio and input lifecycle (Objective-C), App Intents, SharePlay
Owns:
- `Limelight/Stream/Connection.m`, `Limelight/Stream/StreamManager.m`
- `Limelight/Audio/*`
- `Limelight/Input/ControllerSupport.m`
- `Moonlight Vision/AppIntents/*`, `Moonlight Vision/SharePlay/*`
1. `ControllerSupport.m:260`: `dispatch_sync(main)` is now reached on main, because `ClSetMotionEventState` dispatches async to main (`Connection.m:489`). Make it safe; the gyro branch at :290 is the model.
2. `Connection.m:530-539`: on the 10s stop timeout, `initLock` is unlocked while `LiStopConnection` is still running. Keep the lock held until stop really returns, and allow only the UI completion to fire early. Also clear `renderer` and `_callbacks` on that path.
3. Library callbacks read the static `_callbacks` and `renderer` inside the main-queue block (:417-500). Capture them when the callback fires.
4. `ArStop`:
   - set `audioIsStopping` *before* stopping the renderer, and make it `atomic_bool` (:66, :309-313, read at :353)
   - `ArCleanup` should nil `audioRenderer`
   - `OutputAU.m`: call `TPCircularBufferCleanup`, paired with the init at :707
5. `StreamManager.m:124-129`: stopping during the synchronous launch/resume HTTP phase leaves an orphan connection. Add a cancelled check before creating and starting the `Connection` (:106-114).
6. `OpenStreamAppIntent.swift:37` and `DummyView.swift:28`: replace the `try!` and the force-unwraps with proper error handling. Routing the intent through the same launch path as `AppsView` is ticket F's job, so here just stop it crashing.
7. `SharePlayManager.swift:72-86`: a stale session's invalidation clears the current session. Guard with `self.session === session`.
8. Report only, with an assessment of whether each is a real deadlock: `OutputAU.m:336` does `dispatch_sync(main)` while `initLock` is held; `CoreAudioRenderer.m:75` sets the audio session inactive from the library thread.

### C. Settings: bug fixes, then a key registry
Owns:
- `Limelight/TemporarySettings.swift`
- `Moonlight Vision/SettingsView.swift`
- `Moonlight Vision/ControlPanel/*`, `Moonlight Vision/ImmersiveControls/*`
- `MainViewModel.swift`, only the app-list refresh around :575-600
- `RealityKitStreamView.swift`, only the settings and transform persistence: `restoreSavedTransform` / `saveCurrentTransform` (~:3530-3600) and :3954-3983

Swift side only. Leave the Objective-C key strings (`OutputAU.m`, `AUSpatialMixer.m`, `ControllerSupport.m`) alone and list them in your report.
1. The control panels write `preferUninterruptedAudio` straight to UserDefaults (`ImmersiveControlPanelView.swift:268`, `StandardControlPanelView.swift:182,348`). The next `TemporarySettings.save()` then reverts it. Route the write through `streamSettings`.
2. `MainViewModel.swift:585-593`: `updateApps(forExisting:)` runs before `host.appList = newAppList`, which re-inserts deleted apps, and new apps are only saved when something was also removed. Fix the order.
3. Add one typed registry for UserDefaults keys and replace the Swift string literals; there are about 159 `forKey: "…"` sites. Delete keys that are written but never read (`realitykitGamma`, `realitykitSaturation`, …), after confirming they're unused.
4. Merge the three reset paths into one routine: `resetStreamSettingsOnly` (`TemporarySettings.swift:280`), `resetAllSettings` (:328) and `SettingsView.swift:429-436`. Fix the conflicting defaults, e.g. PosZ -2.0 vs `StreamControlState.swift:31` -1.5, and the curvature and dim keys that never get reset.
5. Check this suspected bug: the tilt slider range changed from `-0.5...0.5` to `-60...60` degrees (`SettingsView.swift:302`) without a unit migration. If it's real, migrate the stored values once.
6. Investigate and report, but don't fix unless it's trivial:
   - per-mode values copied into the global `streamSettings`, which then get saved to Core Data (the `restoreSavedTransform` region)
   - `brightness`/`gamma`/`saturation` defaulting to 0.0 in the Core Data model

### D. Deletions
Owns `Moonlight.xcodeproj/project.pbxproj` (removals only), `moonlight-common/moonlight-common.xcodeproj/project.pbxproj` and `Shaders.metal`.
1. Delete `OpenSSL.xcframework/` and `Frameworks/OpenSSL.xcframework/`; both targets use the SPM `krzyzanowskim/OpenSSL`. Remove the group reference in `moonlight-common.xcodeproj` (line ~86/185), and check that `libs/Build-OpenSSL.txt` still makes sense.
2. Delete `Moonlight Vision/StandardControlPanelView.swift`, which isn't in the project; the `ControlPanel/` copy is the compiled one.
3. Delete `Limelight/combined_swift_code.txt`.
4. Remove the `copyFragmentShader*_UIKit` shaders (`Shaders.metal:398-500`), after confirming nothing references them by name string.
5. Remove the Objective-C `Limelight/Database/TemporarySettings.h/.m` from the **XrOS target only** (pbxproj ~1499); tvOS still needs it. Only do this if the XrOS build stays compile-clean.

## Wave 2 — after wave 1 is merged

### E+F. Deepen `RealityKitStreamView`, then add `StreamSession` (one thread, sequential commits)
1. **E, mechanical extractions into new files with no behaviour change:**
   - curved-mesh generation (~:2981-3269)
   - gradient, dimmer-dome and colour utilities (~:3270-3620, excluding the settings persistence)
   - `PCModifierToolbar` (~:3993-4053)
   - the skybox/environment texture cache (~:3757-3842), if it moves cleanly
2. **F, the `StreamSession` module, shared by the RealityKit and UIKit stream views.** Interface: start, stop and suspend/resume, plus an observable phase. It owns:
   - a single phase enum, e.g. `idle | launching | connecting | running | reconnecting(attempt) | suspended | stopping | done`
   - the `StreamManager` and `ControllerSupport`
   - stop-with-completion, plus one timeout policy
   - teardown order (render gate → timers/input → stop → wait → audio reset)
   - saving the resume config
   - the host-online reconnect probe

   Things to fix along the way:
   - Replace the scattered flags: `hasPerformedTeardown`, `needsResume`, `isReconnecting`, `isPerformingReconnectTeardown`, `renderGateOpen`, `firstFrameReceived`, `isReconnectingForRetry`, `activelyStreaming`.
   - Make `MainViewModel.streamState` `private(set)` with transition methods, so there's one writer.
   - UIKit resets audio before stop and fakes teardown with 0.3/0.5s delays (`UIKitStreamView.swift:231,353,435-449`).
   - The 5s timeout path in RealityKit resets audio while the stream may still be running (:2751).
   - Background resume doesn't wait for the previous stop (:415-447).
   - `usleep` on main (:938, `InputCaptureUIView.swift:570`).
   - Route the App Intent through the same launch path.
   - The `animationTimer` and `modeLabelTimer` invalidation is missing.

   The ~26 stringly-typed lifecycle notifications should mostly disappear; remove the ones that do.

### G. Shimmer — needs Luke on device
This is a diagnosis, not a fix. It waits for wave 1, because the decoder fixes change IDR and parameter-set behaviour. Luke's report: RealityKit renderer, HDR on, "Automatic" codec, curved screen. It shimmers on still content as the head moves, worst in peripheral vision. That points at under-filtered minification: `makeVideoUnlitMaterial` binds the mipmapped drawable with the default sampler, so there's no anisotropy. Started before wave 1 finished, since it doesn't touch the decoder.

### Final: `/code-review` of the integration branch against `vision-testflight`.

## Status

| Ticket | Thread | Branch | State |
|---|---|---|---|
| A decoder | @thread:thr_ewqb8v2dae | bb/cleanup-a-decoder-correctness-thr_ewqb8v2dae | merged |
| B lifecycle | @thread:thr_hewxt4aksp | bb/cleanup-b-connection-audio-lifecycle-fixes-thr_hewxt4aksp | merged |
| C settings | @thread:thr_rtzxjcquha | bb/cleanup-c-settings-fixes-key-registry-thr_rtzxjcquha | merged |
| D deletions | @thread:thr_978eyitr5x | bb/cleanup-d-dead-code-and-asset-deletions-thr_978eyitr5x | merged |
| E+F StreamSession | @thread:thr_f7mz2irbqy | own worktree | E done (4057→3200 lines); F design approved, phase 2 running |
| G shimmer | @thread:thr_c5z7nwws7h | bb/cleanup-g-realitykit-shimmer-sampler-filtering-thr_c5z7nwws7h | merged (sampler + A follow-up `32eb221`, present via command buffer); needs Luke on device |
| Review | | | |

## Decisions and notes
- No test target, because the simulator can't link and adding one now is YAGNI. The phase enum in F is the best candidate for the first real tests once the app links.
- The broken link on `fb34983` is out of scope for this work, but Luke should know about it.
- B: `ArStart`/`ArStop` were never registered with the library, so `audioIsStopping` was always false and the audio engine was never stopped between streams. Removed them; `ArCleanup` now stops and releases the renderer. `OutputAU.m:336` `dispatch_sync(main)` under `initLock` isn't a deadlock today, but would become one if F ever blocks main waiting on stop or start. The same goes for A's `main.sync` in `setupLowLevelTexture`.
- D: `OutputAU.m:17` imports `TemporarySettings.h` without using it (left for F or a later pass).
- A: the decoder now owns a per-frame atomic gate, `isRenderingEnabled`, and closes it in `stop()`. The view's teardown doesn't use it yet; F should close it at the start of teardown and delete `renderGateOpen`. Each session now holds a strong reference to the decoder (`passRetained`) until the session is invalidated, so a missed `stop()` leaks rather than crashes.

### Inputs for F, collected from wave 1
- **Never block main on start or stop.** `setupLowLevelTexture` does `main.sync` and `OutputAU.m:336` does `dispatch_sync(main)`, both under `initLock`. Neither deadlocks today; both would if main ever waited on the connection. If you can, switch `setupLowLevelTexture` to `main.async`. That needs a lock around `drawableQueue`/`ambilightQueue`, and the `fatalError` when creating the `DrawableQueue` fails should go too.
- **Off-main reads in `rendererProvider`.** It runs on StreamManager's background queue but reads `viewModel.streamSettings.enableHdr` and `connectionCallbacks`.
- **A stop that never returns.** After B's `7101805`, if `LiStopConnection` never returns, the next `Connection.main` waits on `initLock` forever and the UI sits on "connecting". The timeout policy should surface that to the user.
- **`MainViewModel.stream(app:)`** calls `prepareForNewStream()` before its guards, so a nil return still changes state.
- **Off-main read of `firstFrameEmitted`.** It's read on main and written on the VT thread; harmless today. The phase enum should own first-frame state.
- **Out of scope for F, but needs its own on-device ticket:**
  - `OutputAU._isPlaying` is never set, because `-start` is never called. So route and configuration changes (e.g. connecting AirPods mid-stream) never reconnect the audio nodes.
  - visionOS `ObservableConnectionManager.setMotionEventState`/`setControllerLed` only print, so gyro and LED never reach `ControllerSupport`.
- C: `SettingsKey` lives in `TemporarySettings.swift`, because a new file would have needed a pbxproj edit. One reset routine: `resetToDefaults(includingSystemSettings:)`. `StreamControlState` owns the immersive defaults. The tilt migration was skipped: old values never took effect, so there's nothing to migrate.

### Inputs for F, collected from wave 1 (continued)
- **Per-mode display values leak into global settings.** `restoreSavedTransform` copies volume/immersive gamma, saturation, brightness, curvature and dim into `streamSettings`, and `saveRealityKitSettings` then writes them to Core Data. Keep per-mode display params in their own object.
- **`saveCurrentTransform()`** is called from `teardownScene` (~:1264). It still writes the legacy `immersive.pos`/`immersive.scale` and ignores `rememberStreamSettings`. Remove the call.
- **Dead keys in `RealityKitStreamView`:**
  - `immersiveInputMode`: written, never read
  - `ambient.dimming.level`: written only
  - `immersive.defaultControlMode`: read, never written
- **Swift key literals left outside C's scope:**
  - `AudioHelpers.swift:18`
  - `InputCaptureUIView.swift:128,501`
  - `UIKitStreamView.swift:483-484,692-693`
  - `MainViewModel.swift:76`
  - Move the ones in F's files onto `SettingsKey`.

### Open questions for Luke
- `dimPassthrough` defaults to `false` on a fresh install, but "reset all" sets it to `true`. Which is right? C kept `true` for reset.
- The Core Data model still defaults `brightness`/`gamma`/`saturation` to 0.0. C works around it at load time. Do you want a `v1.11` model version with real defaults?
- G: RealityKit's default sampler was already trilinear, so the starting hypothesis was mostly wrong. Merged: 16× anisotropic + clamp-to-edge for every video material, and the SBS ShaderGraph moved to `RealityKitTexture2D` (checked pixel for pixel against the old graph offscreen on macOS). This helps oblique sharpness and edge bleed, but probably not the shimmer itself. Also found: the decoder presents drawables before the command buffer completes (sent to A as a follow-up).

### Shimmer experiments for Luke, in order
1. Build this branch and compare against `e32aa65`. Use small static text, view the curve edge-on, and watch the screen border.
2. If it still shimmers, add `sampler.lodBias = 0.5` in `videoTexture(_:)`. That's one line; it trades a softer picture for less aliasing.
3. Change the stream resolution and the screen distance. Does the shimmer track the texel-to-pixel ratio?
4. Turn HDR off. If the shimmer goes, the cause is linear-vs-PQ values in the `rgba16Float` texture, on the decoder side.
- E: extracted `PCModifierToolbar.swift` and `CurvedScreenMesh.swift`. Deleted the dead dimmer-gradient/moonlight-cycle code (no callers since `7829498`, yet it rendered eight 1024px textures per immersive launch) and the inert 360° skybox (no assets ship, and its levels are always 0).
- F design approved, with changes:
  - `streamState` is computed from `activeSession?.phase`, rather than mirrored through a sink
  - the end-of-session policy runs in an end hook
  - F also fixes the `terminate`-before-`main` orphan race in `Connection.m`

### Open questions for Luke (continued)
- Dimming-picker options 5–14 (Midnight, Twilight, Dawn…) have done nothing visible since `7829498`; only levels 1–4 set an opacity. Remove them from the picker, or bring them back?
- `hideHandsIn360Environment` has no effect, because the 360° environment was never wired up. Remove the setting?
- Luke: the shimmer is on the curved screen viewed roughly head-on, and sharp text is worst, so it's aliasing at ~1:1 rather than an anisotropy problem. G is adding a live "Text anti-shimmer" mip-bias setting (default 0) so it can be tuned on device. Luke approved removing dimming options 5–14 and `hideHandsIn360Environment`; that's assigned to F's final commit. When everything is done, push the integration branch to `origin` (banjerluke) for Luke's HDR test.
