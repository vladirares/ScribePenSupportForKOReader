# Scribe Ink 0.4.3

An installable KOReader plugin for freehand PDF handwriting on a jailbroken Kindle Scribe. A compact, collapsible left-side dock offers Pen, Erase, Undo, PDF export, and the KOReader menu. Tap Pen to choose a line width. Fingers navigate normally; the pen writes automatically, with palm rejection while the pen is nearby.

Designed for the user's Kindle Scribe 2024, firmware **5.19.6**, and **KOReader 2026.07.1**. The user confirmed faster writing, the left dock, and rear-eraser input in earlier releases. **0.4.3 needs confirmation on the device.** It shows the actual white eraser contact area and clears fast-refresh artifacts with one regional flash after lift.

Version **0.4.3** replaces the outlined eraser cursor with a temporary solid white footprint, matching the area being erased. On lift, it restores the page image and performs one prompt, regional `flashui` refresh to clear artifacts from fast refreshes. This release needs on-device confirmation.

Version **0.4.2** shows the eraser footprint only during physical contact. It hides the cursor on release and ignores hover for display updates. Contact erasing uses fast local refreshes; after the gesture ends, a single delayed regional UI refresh clears any remaining e-ink ghosts, including along the cursor trail. Brief `BTN_TOOL_RUBBER` signal dropouts remain tolerated. The cursor is transient and is never saved to notes or exported PDFs.

Version **0.4.1** shows a thin white halo and dark outline around the active rear eraser or selected tip eraser; the cursor is transient and is never saved to notes or exported PDFs. Erasing recomposes the cut and surviving ink directly from the clean page snapshot and asks KOReader to refresh that screen region without repainting the full reader page. The input decoder keeps a pressured rear-erasing contact continuous if firmware briefly drops `BTN_TOOL_RUBBER`.

Version **0.4.0** erases only the crossed section of ink, splitting a line into surviving paths. One Undo restores an entire eraser gesture. The black eraser cursor is removed completely. Successful erasures redraw the affected strokes from the actual PDF and current ink, and request the page-content display waveform, instead of relying only on a cached-area monochrome refresh. This addresses lingering ink and covers stale-snapshot and display-update causes; the earlier hardware observation does not distinguish those causes. Refresh requests are combined once per input batch, without advancing KOReader's page-flash counter. The pen icon opens a small picker for **0.75, 1.25, 2, or 3 pt**; the selected width is saved for new strokes.

Version **0.3.0** removes the public Reading/Writing toggle. Finger navigation and pen capture coexist automatically. KOReader's supported stylus callback consumes duplicate pen events before gesture recognition, while finger input remains available when the pen is away. The previous top toolbar is replaced by a narrow left dock, matching the reference's layout. Tap its chevron to collapse/expand it. Notes, calibration, and the faster incremental rendering path are preserved. Regional erasing now also preserves rounded caps of thin surviving strokes near the erased area's edge.

Version **0.2.0** keeps the writing toolbar visible on PDFs by default and starts writing automatically. Pen updates now draw only the new segment and request a small screen refresh instead of repainting the PDF and all saved strokes. Erasing restores a cached clean area and replays intersecting surviving ink. A faster scanline renderer uses 5.4 times fewer paint calls on the included handwriting benchmark and 28.6 times fewer on long-stroke samples; these are host-side work measurements, not measured Kindle speedups. Disk saves run after a short idle period to avoid stalling a sequence of strokes. Existing JSON notes and calibrations remain compatible.

Version **0.1.1** fixes the missing Scribe Ink menu reported by the user. In 0.1.0, menu creation failed because a numeric loop variable shadowed the translation function (`main.lua:81: attempt to call local '_' (a number value)`). A regression test now builds the plugin's actual menu and checks its actions. To update, exit KOReader and replace the installed `scribeink.koplugin` folder with the folder in the new archive, then restart KOReader. Keep only one installed copy of the plugin. Existing handwriting files and settings are compatible.

## Install

1. Exit KOReader and connect the Kindle to the computer over USB.
2. Open `scribeink-0.4.3-install.zip`. Copy the **entire `scribeink.koplugin` folder** into your existing `koreader/plugins/` folder on the Kindle, replacing the previous version if installed. A usual location is `/mnt/us/koreader/plugins/`; some launchers place KOReader elsewhere. Find the folder that already contains other `.koplugin` folders.
3. Confirm this structure, without an extra nested folder:

   ```text
   koreader/
     plugins/
       scribeink.koplugin/
         main.lua
         _meta.lua
         input.lua
         ...
   ```

4. Safely eject the Kindle and restart KOReader. If user plugins are disabled, enable them in KOReader's plugin management and enable **Scribe Ink**, then restart.
5. Open a PDF. The left-side dock appears and pen capture starts automatically. Use your fingers to navigate and the pen to write. Configuration remains under **Tools → More tools → Scribe Ink**, accessible using the dock's bottom menu icon. **Show pen controls** can retry capture after an error.

There are no additional native binaries, startup scripts, root filesystem changes, or Kindle services to install. The plugin uses KOReader's bundled LuaJIT and MuPDF libraries.

## Write and erase

Use single-page PDF view, with reflow off and **PDF page rotation set to 0**. Screen orientation can be portrait or landscape. Existing intrinsic rotation stored in the PDF itself is supported.

On the first start, tap each of the three displayed crosses once with the pen **tip**, lifting between taps. Calibration handles swapped, reversed, and differently scaled digitizer axes. It is saved for each screen orientation and input device. Use **Recalibrate pen** if handwriting is offset.

- Write with the pen tip automatically. Flip the pen and touch the page with its rear eraser to erase. While touching, a transient solid white circle shows the eraser footprint; the page is restored when you lift. It is not part of saved ink or the exported PDF.
- Tap **Erase** to erase using the tip. This is also a usable fallback when the physical rear signal is unavailable. Tap **Pen** to return to writing.
- Erasing removes the **part of handwriting beneath the eraser**, leaving the rest of each stroke. Fast sweeps are continuous between input samples, and sparse lines are split at interpolated cut points. This applies to existing sidecar notes as well as new ink. Printed PDF content and annotations made in other applications remain intact.
- **Undo** reverses one pen stroke or one eraser gesture. Undo history is limited to the current open-document session, up to 100 actions.
- Use ordinary finger gestures on the document to turn pages, zoom, or pan. Lift the pen away from the page to navigate; palm gestures are rejected while the pen is nearby and briefly after contact ends.
- The dock's top chevron collapses it to a small handle. Expand the handle to access the pen, eraser, undo arrow, export arrow, and bottom menu icon. The selected tool is white on black. There is no Reading/Writing toggle.
- Tap the bottom **menu icon** to access KOReader's menu. Finger taps and pen-tip taps both operate the dock; the rear eraser does not activate dock buttons.
- Tap the dock's **pen icon** to choose **0.75, 1.25, 2, or 3 pt**, with the current choice marked. Selecting a width closes the picker and keeps Pen selected. It changes new strokes; existing handwriting keeps its width. The **Pen width** submenu offers the same choices. Width does not vary with pressure, and the pen's side button has no assigned action.

Only the dock's small rectangle and the page margins are excluded from pen capture. The rest of the page remains available. Screen rotation saves the current stroke and automatically reopens capture; an uncalibrated orientation requests three pen-tip taps. Calibration is remembered separately for each orientation.

## Save and export

Strokes are saved automatically after **0.75 seconds with no new stroke**, and immediately on export, opening the dock menu, suspend, or document close. Beginning another stroke defers the idle save so disk serialization and sync do not run during handwriting. A crash or loss of power before the idle save can lose the most recent unsaved strokes. Saved notes remain visible when you reopen the original PDF with the plugin enabled.

For a PDF named `book.pdf`, the plugin writes:

```text
book.pdf.scribeink.json       current editable handwriting
book.pdf.scribeink.json.bak   preceding saved handwriting, when available
```

Keep the PDF and its JSON sidecar together when copying or backing up your notes. The plugin uses a full source-file checksum to avoid attaching ink to a replaced or edited PDF. A previous saved version is recovered with a message if the main JSON is malformed. An interrupted first save can be recovered from a valid `.tmp` when no installed save or backup exists.

Tap the dock's **export arrow** or choose **Scribe Ink → Export annotated PDF copy**. On KOReader 2026.07.1, handwriting is embedded as standard PDF **Ink annotations** with appearance streams. The resulting file can be opened on a computer and contains the original PDF content and existing annotations. Each export creates a new available filename such as `book-annotated.pdf` or `book-annotated-2.pdf`. Previous exports are snapshots: after erasing more ink, export again to obtain the updated copy.

The plugin's handwriting/export path leaves the source PDF unchanged. KOReader can still embed its own text highlights into that source if you have enabled its PDF writing options. The plugin follows those deliberate KOReader writes and updates the sidecar checksum. If KOReader reports pending PDF edits during export, close and reopen the document, then export. As with any two-file save, interruption between KOReader writing the PDF and the plugin updating its sidecar may require restoring a matching backup pair.

If saving fails, the plugin reports the error and retains the current ink in memory. Fix the storage problem and retry saving **before closing the document or restarting**. The plugin cannot preserve unsaved memory through a restart.

Runtime capability checks protect older/mismatched builds. Native ink export requires KOReader's ink API, shipped in 2026.07 and later. For older builds, or password-protected PDFs that cannot be reopened by the on-device exporter, the included `tools/export_pdf.py` offers a computer export path; see `tools/README.md`.

## Troubleshoot

**The crosses do not respond:** use the dock's bottom menu icon, then choose **Tools → More tools → Scribe Ink → Pen input source → Prefer scaled virtual pen (fallback)**. The capture restarts automatically. The default prefers the physical Wacom device; a firmware's pen service can make a virtual device the usable source. Both sources are checked for pen, coordinate, and contact capabilities. Neither is grabbed exclusively.

**Writing works but the rear eraser does not:** 0.2.0 recognizes pressure contact from an identified eraser even when its driver omits `BTN_TOUCH`. It also supports explicit **Rear eraser signal** selection: rubber tool (default), stylus button 1, or stylus button 2. Do not select a button mapping unless the diagnostic capture shows that the rear eraser actually uses it; those buttons can be the pen's side buttons on other devices.

For the supplied Scribe log, leave **Rear rubber tool (default)** selected. The observed signal is already correct. Touch and move the rear eraser across a freshly written line on the same original PDF. The crossed section should disappear without changing pages, leaving ink on both sides. Version 0.4.3 shows a transient white eraser footprint during contact and requests one local cleanup refresh on lift. The log adds `Scribe Ink eraser stroke` entries with decoded/accepted samples, altered-stroke count, rejection reasons, and raw/screen/page coordinates. If it still fails, share the updated log after this ordinary erase attempt.

Choose **Scribe Ink → Test rear eraser (10 seconds)**. While its instruction is visible, repeatedly touch and lift the rear eraser on the page for ten seconds. Handwriting capture pauses during the test. The resulting raw key/pressure summary appears on screen and is written to `crash.log`. Share that summary or the updated log to identify the correct signal. The capture records even events that did not become a recognized stroke. You can use **Erase** with the tip meanwhile. Ordinary finger touches never become eraser strokes.

**Writing is misaligned:** use **Recalibrate pen**, tapping the centers of the crosses. Confirm reflow is off, continuous view is off, and reader page rotation is 0.

**The plugin fails to load:** verify folder nesting, user-plugin settings, and KOReader's `crash.log` in its installation directory. To uninstall, exit KOReader, remove only `scribeink.koplugin` from `plugins`, and restart. Your handwriting sidecars and exported PDFs remain in the documents folder. Disabling the plugin hides the sidecar ink until it is enabled again; exported PDF annotations remain visible elsewhere.

**Source checksum mismatch:** preserve the JSON and restore the PDF version it belongs to. Arbitrary outside edits that reorder or resize pages are not automatically migrated. Editing an exported annotated PDF does not update the original document's sidecar.

## Validation and source

Original implementation licensed under AGPL-3.0-or-later. The source archive includes tests and the optional computer exporter. Development tests require Python 3.10+, `lupa`, and `PyMuPDF`:

```text
python -m pip install -r tests/requirements.txt
python tests/run_tests.py
```

Checks cover coherent pen frames, hover/contact distinction, rear eraser pressure fallback, short rubber-key dropout tolerance and button mapping, a representative replay of the user's logged rear-key sequence, raw diagnostics, native pen-slot suppression and callback ownership, input overruns and disconnects, descriptor cleanup, calibration, clipped line pixels, page transforms, partial erasure of sparse and curved paths, exact grouped undo, saved/reopened fragments, storage failures, checksum checks, backup recovery, internal KOReader PDF writes, compact dock hit areas, eraser-footprint feedback, the pen-width picker, unified finger/pen interaction, screen-refresh dispatch, and deferred saving. PDF tests also check real exported annotation gaps, searchable text, original annotations, cropped/rotated pages, and failure paths. Native KOReader export is exercised against a mocked API; actual PDF output is exercised with the companion desktop exporter. The newest integration remains unverified on physical hardware.

Primary integration references:

- [KOReader 2026.07.1 Kindle device support](https://github.com/koreader/koreader/blob/v2026.07.1/frontend/device/kindle/device.lua)
- [KOReader 2026.07.1 reader page transforms](https://github.com/koreader/koreader/blob/v2026.07.1/frontend/apps/reader/modules/readerview.lua)
- [MuPDF Lua wrapper used by KOReader 2026.07.1](https://github.com/koreader/koreader-base/blob/6e4bc81af4e04f78d81677a323a780a71b29702a/ffi/mupdf.lua)
- [Scribe input event investigation](https://github.com/koreader/koreader/issues/11156)
- [Linux input event protocol](https://docs.kernel.org/input/event-codes.html)

This plugin uses software pen rendering and KOReader's refresh scheduling. It does not integrate Amazon's native handwriting acceleration, so matching the original application's latency is not guaranteed.
