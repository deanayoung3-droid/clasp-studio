# Clasp Studio 2.0.2

A native macOS app for recording a camera and selected microphone with broadcast graphics and a voice-following teleprompter. Supports macOS 14 or newer, Apple silicon and Intel. The preview app is ad-hoc signed and not notarized.

## Open this update

Quit an older running copy before opening `outputs/Clasp Studio.app`. Studio settings shows version **2.0.2**. Replacing the files of an app does not update a process that is already running.

## Record a take

Choose your camera and microphone below the preview. **Start recording** immediately opens the focused preview and teleprompter, connects the devices if necessary, and shows a connection/startup status. Allow the camera and microphone permissions requested by macOS. The red recording indicator and elapsed time begin after the first video frame has been written successfully. **Cancel** stops pending setup; **Stop recording** finalizes the movie. Permission, camera connection and first-frame waits have explicit timeouts and errors. **Cancel connection** below the preview cancels a device connection before recording.

Recordings save first as clean camera-and-microphone drafts. **Stop recording** opens the timeline editor before final export. Trim, cut, rearrange and add graphics or supporting media, then choose **Export** to save a 1280 × 720 MP4. Final exports default to `~/Movies/Clasp Studio`; change that folder in Studio settings. **Show in Finder** opens the destination folder with the finished movie selected. Apple camera effects remain in the source image; graphics and mirroring can be changed in the editor. **No microphone** produces silent video. **Exit focus** returns to the studio while a take continues.

## Your script and voice

**Import script** accepts TXT, Markdown, RTF, DOCX and text-readable PDF. **Edit / paste** opens the script editor. Add `# headings` to separate sections, or blank lines between paragraphs.

**Follow my voice** is the default mode. Click **Connect & listen** / **Start listening**, or start recording, to request Speech Recognition permission and follow the script using the selected microphone. Read the highlighted words; the cue advances as recognized words match the script and holds during silence or off-script speech. The listening status and mode switch remain visible during recording. Voice following uses Apple's on-device English recognition. **Reading pace** provides timed scrolling when voice recognition is unavailable. Your selected mode is saved. Selecting a section or restarting pauses listening at the new position.

Voice, camera, and microphone permissions are managed by macOS. If denied, enable the app in System Settings → Privacy & Security. The app reports an unavailable recognizer or a microphone that delivers no audio instead of silently appearing to listen.

## Overlay library and sponsor carousel

**Overlays** opens the library with six designs based on the supplied SVGs: **Law · Classic**, **AI · Editorial**, **AI · Blue**, **AI · Graphite**, and **Law · Glass**. The reference photograph is removed entirely; the selected live camera fills its window. Switching designs preserves each entry’s edits. Duplicate an entry for a new show or episode.

**Content** edits the title, episode date, presenter, handle, headline panel heading, script card titles, LIVE label and clock time zone. Visibility switches control the date, presenter, headlines and LIVE badge. **Branding** changes the brand name, subtitle, presented-by label, uploaded brand/program logos, accent and LIVE colors, and title size. The app icon uses the vector Clasp mark.

**Sponsors** edits up to twelve sponsor names, uploads/replaces/removes logos, changes their order, and enables or hides individual entries. The default strip uses the supplied Microsoft 365, Confido Legal, Citizens Private Bank and Crabtree Law artwork. Renaming a preset displays its icon beside the edited name. Sponsor edits are shared across the library. **Scroll continuously** and **Scroll speed** control the seamless carousel; **Show sponsors** hides it for the selected overlay. The LIVE indicator pulses while previewing and recording. Both animations respect macOS Reduce Motion.

The preview and saved movie share a cached Core Image compositor. Text, logos, camera masks and sponsor tiles are rasterized when settings change; each frame only fits the camera, translates the carousel, and adjusts LIVE opacity. The offline preview uses a neutral camera placeholder.

## Apple backgrounds and Continuity Camera

Custom background images, app blur, person segmentation and edge-adjustment controls have been removed. Old saved background images are discarded when opening the project. **Apple backgrounds & effects** below the preview opens macOS Video Effects after connecting the camera. The OS controls available Background, Portrait, Studio Light and other effects; availability depends on hardware and macOS version. Apple's background replacement requires macOS 15 or newer and supported hardware.

Continuity Camera is explicitly enabled. Make the iPhone available to your Mac, refresh the device list, and select its camera entry, marked **iPhone**. An external microphone can be selected independently.

## Performance and session status

No custom Vision segmentation runs. Supported cameras capture at 30 fps rather than spending extra work on high webcam frame rates. The live preview uses Core Image and Metal with a single latest-frame slot and at most one GPU preview in flight. Waiting for a display texture happens away from the main UI thread. Microphone delivery to Speech runs independently of video encoding. Speech accepts at most eight queued audio samples, retains the newest pending transcript, and backs off between idle recognition restarts. The script tokens are cached and long scripts use lazy UI lists.

Studio settings → **Session status** shows whether the camera and microphone are delivering data, and recent connection, permission and recording events. **Save session status…** exports these events without recording audio or transcripts. Actual camera latency and speech recognition must be checked on the selected hardware; synthetic encoder and matcher tests are not a substitute for that check.

Projects are saved locally in `~/Library/Application Support/ClaspStudio/project.json`. Recordings stay on your Mac.

## Build and verify

Run `outputs/ClaspStudio/build.sh --universal` from the workspace to build the app for Apple silicon and Intel, verify the staged ad-hoc signature and make the preview ZIP. `package-dmg.sh` is available for the non-notarized DMG after preview approval.

The executable supports:

- `--self-test --test-output /absolute/path/check.mov`: test script imports, saved-project compatibility, real H.264/AAC encoding/decoding with synthetic inputs, recording transitions, cancellation, full-screen coordination, all six camera windows, overlay-library persistence, sponsor edits and seamless tiling, LIVE animation, animated recording, speech matching, and Metal orientation. Prints a 120-frame compositor benchmark.
- `--camera-check`: read-only six-second camera timing check when camera permission is already available. Does not request permission.
- `--render-preview /absolute/path/preview.png --voice-preview`: render the native UI without opening a studio window or modifying the saved project.
- `--render-preview /absolute/path/preview.png --template AI` (or `Law`, `AIBlue`): preview a library design.
- `--render-preview /absolute/path/editor.png --editor-preview --sponsors-preview`: preview the sponsor editor; omit `--sponsors-preview` for content editing.
- `--render-motion /absolute/path/preview.gif --template AI`: export an animated compositor preview.
- `--render-preview /absolute/path/preview.png --focus-preview`: render the focused recording layout.
- `--render-preview /absolute/path/preview.png --starting-preview`: render the pending connection/recording layout.

Earlier live-capture checks verified the library, design selection and sponsor controls in the running desktop app. The new editor is additionally covered by native offscreen previews and automated composition/export checks. After macOS authorization completed, the MacBook Pro camera displayed live inside the AI overlay with an Apple background active. A short live recording entered full screen, displayed only the preview and teleprompter, saved successfully, and decoded at 1280 × 720 with video and microphone audio tracks. Synthetic checks also verified movie encoding/decoding, all three camera windows, sponsor animation, editing persistence and transcript matching. A spoken read-through is still needed to verify live voice recognition with the selected microphone.

## Component editor

Open **Overlays** and choose a design in **Designs**. The library includes Law · Classic, AI · Editorial, AI · Blue, AI · Graphite and Law · Glass. The **Layers** tab lists the design’s semantic regions. The canvas shows a sample camera picture. Click the title, badge, brand block or headline panel to edit it in the inspector. Hidden regions remain available in the component list.

Titles and headlines support text scale, alignment and inset. Text stays inside the lower third or headline cards. Presenter names and handles occupy separate columns. LIVE and presented-by positions swap safely between the top corners of the camera. The camera crop is protected, and uploaded logos keep their original proportions.

Each overlay saves component settings independently. Duplicate a design to create another episode layout. Sponsor content and ordering remain shared across the library. New Graphite and Glass designs are added once when an older project is opened, preserving previous edits.

## Edit a recording

New recordings are clean camera-and-microphone drafts. Press **Stop recording** to open the broadcast editor before exporting. Choose **Import video** in the studio to edit Zoom footage or another MOV/MP4 instead. **Drafts** reopens saved edits.

Click a clip or drag the timeline ruler to scrub. **Layers** lists each shot’s video, picture, overlay, transition and audio. Selecting a layer shows only its controls in the inspector. The floating canvas toolbar switches between those controls. **Assets** holds imported media. Select a clip, set in/out points, or drag its white edges to trim. **Split** cuts at the playhead; **Remove** deletes a selected piece from the timeline. Drag a clip’s middle to reorder it, or use Earlier / Later in its inspector. Undo and redo restore edit states; source files are untouched.

The clip inspector controls the picture, overlay, active headline and audio. **Image / video** replaces the presenter picture with supporting media. **Split screen** puts the presenter beside an image or guest video. Turn **Show topics sidebar** off to expand the picture; turn **Show overlay** off for a clean full-frame shot. Images fit without cropping unless **Fill and crop** is enabled. Guest videos loop to cover the clip, with optional guest audio.

## News transitions

Split at a speaker change and select the incoming clip. Its transition can be **Cut**, **News wipe**, **Fade through black**, or **Library animation**. The animation library accepts multiple MOV/MP4 clips, supports rename and removal, and lets you preview before applying a stinger. Transparent ProRes MOVs appear over the picture. Animation audio mixes with the program and lowers presenter audio during the stinger.

## Final export

Choose **Export**, select a name and folder, and wait for the progress indicator. The finished movie is a 1280 × 720 MP4. The saved confirmation’s **Show in Finder** button selects the exported file. Canceling an export keeps the draft and source media; completed exports replace an existing movie only after the new file finishes successfully.

Drafts autosave under `~/Library/Application Support/ClaspStudio/Drafts`. The animation library lives under `~/Library/Application Support/ClaspStudio/Animations`. Apple video effects remain in the recorded camera image. Graphics already burned into imported recordings cannot be separated into editable layers.

## Expanded video editing

The Video inspector provides frame stepping, duplicate, playback speed from 0.25× to 4×, zoom and horizontal/vertical crop positioning. Picture controls include adjustable splits, swapped sides and picture-in-picture. Animation transitions have a source start, start time within the shot, duration, opacity and volume. Drag their timeline bar to move them within that shot. Use **Preview transition** to play from the effect. **Clasp reveal** supplies a cached three-panel broadcast transition.

Law · Glass now blurs only the camera pixels behind its frosted panels. Blur and tint can be adjusted in the Headlines inspector. Law · Ticker uses the original supplied vector branding and an upward scrolling headline beside the brand, following script sections. Its camera remains full frame.
