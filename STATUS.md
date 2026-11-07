# ZImage status

Dated iteration log. Newest entry first.
One entry per session that changes the product or the plan.
This file is not a second design document.

## Entry format

Each entry uses this shape:

## YYYY-MM-DD — title

- Status: not started | in progress | blocked | done
- Scope: design section or PR name
- Notes: facts, decisions, and the next step

## 2026-11-07 — Docs match the tree

- Status: done
- Scope: DESIGN.md, README.md, and the GitHub repo.
- Notes: DESIGN no longer says the tree is an empty template. README says what the two apps are and how to build them. The helper binary stays out of the repo.

## 2026-11-06 — Crop handles take the drag

- Status: done
- Scope: ZImage editor Select and Crop.
- Notes: While Select is on, the hand pan is not installed, so the pointer stays on the crop handles and a drag moves those handles. Space pans again after leaving Select. The helper was not changed.

## 2026-11-06 — Touchup title folds

- Status: done
- Scope: ZImage editor Touchup panel.
- Notes: The Touchup title has the same disclosure as Tone, Color, Geometry, and History. Down is open. Up leaves the title. The choice is kept in `ZImage.inspectorTouchupCollapsed`. The helper was not changed.

## 2026-11-06 — Saved photo opens on the stored picture

- Status: done
- Scope: ZImage editor reopen after Dust.
- Notes: Switching away from a dusted photo and back shows the picture that was on screen. A later launch shows the JPEG already stored in the `.zimg`. Dust does not run again until the next edit, undo, or export. The edit log stays the source of truth. The helper was not changed.

## 2026-11-06 — Scratch drag keeps the pointer

- Status: done
- Scope: ZImage editor Touchup panel.
- Notes: Scratch leaves the arrow cursor in place and redraws the circle while the button is down. The helper was not changed.

## 2026-11-06 — Scratch blend lands on the stroke

- Status: done
- Scope: ZImage editor Touchup panel.
- Notes: Letting go of Scratch blends the gray stroke itself. The click was mirrored, so the repair had been landing on the other side of the photo. The helper was not changed.

## 2026-11-06 — Scratch stroke blends the gray area

- Status: done
- Scope: ZImage editor Touchup panel.
- Notes: Letting go of Scratch blends the whole gray stroke into the photo beside it. The helper was not changed.

## 2026-11-06 — Touchup drag cursor

- Status: done
- Scope: ZImage editor Touchup panel.
- Notes: Scratch no longer hides the system cursor. The circle and the gray stroke stay visible for the whole drag, and the stroke is redrawn about 40 times a second. The helper was not changed.

## 2026-11-06 — Touchup circle size

- Status: done
- Scope: ZImage editor Touchup panel.
- Notes: Spot and Scratch share a Size slider. The circle follows the pointer and limits the search. Scratch is a drag that grays the covered stroke until the mouse is released. The helper was not changed.

## 2026-11-06 — Dust and scratch touchup

- Status: done
- Scope: ZImage editor Touchup panel.
- Notes: Dust and Scratches find defects and blend them into the surrounding photo. Spot marks one speck. Scratch marks the two ends of one scratch. The Dust and Scratches sliders mix that repair from full down to none. The helper was not changed.

## 2026-11-06 — Inspector uses one scrollbar

- Status: done
- Scope: ZImage editor inspector.
- Notes: Open Tone, Color, and Geometry are as tall as their controls. History is as tall as its steps. The column has one scrollbar when the window is shorter than that stack. The helper was not changed.

## 2026-11-06 — Zoom is the default tool

- Status: done
- Scope: ZImage editor canvas toolbar.
- Notes: The Hand button is hidden. Zoom is selected when an image opens, and again after leaving Select, Horizon, the eyedropper, or a finished crop. Space still pans. The helper was not changed.

## 2026-11-06 — Space shows the hand cursor

- Status: done
- Scope: ZImage editor canvas.
- Notes: Holding Space, or using the Hand tool, shows an open hand over the image. Dragging shows a closed hand. The helper was not changed.

## 2026-11-06 — Canvas well is dark gray

- Status: done
- Scope: ZImage editor canvas.
- Notes: The area around the photograph is `#5C5C5C`. The helper was not changed.

## 2026-11-06 — Horizon and Eyedropper toggle

- Status: done
- Scope: ZImage editor Geometry and Color panels.
- Notes: Horizon and the eyedropper icon toggle. Brown border while the tool is on, thin black border while it is off. A second click returns to Hand. The helper was not changed.

## 2026-11-06 — Color sits above Geometry

- Status: done
- Scope: ZImage editor inspector.
- Notes: The inspector order is Tone, Color, Geometry, History. Each panel keeps its height and its collapse state. The helper was not changed.

## 2026-11-06 — Inspector panels collapse

- Status: done
- Scope: ZImage editor inspector.
- Notes: Tone, Geometry, Color, and History each have a disclosure at the right of the title. Down means open. Up means collapsed to the title. The open height is kept. Horizon sits at the right end of the Rotate row. The eyedropper icon sits at the right end of the White and Skin row. The helper was not changed.

## 2026-11-06 — Color panel holds Temperature and Tint

- Status: done
- Scope: ZImage editor inspector.
- Notes: The third inspector panel is titled Color. Temperature and Tint sit at the top of it. The tool button is an eyedropper icon. White and Skin stay under those sliders. The menu command remains Eyedropper. The helper was not changed.

## 2026-11-06 — Sharpness in Geometry

- Status: done
- Scope: ZImage editor Geometry panel.
- Notes: Sharpness is a −1...1 slider in Geometry, after Horizontal. Zero leaves the image. Positive is a fine unsharp mask with radius `1 × longEdge / 2560`, applied after the geometry transforms and before the crop. Negative softens. Older geometry records without the field stay at 0. Texture and Clarity stay in Tone. The helper was not changed.

## 2026-11-06 — Copy and Paste settings

- Status: done
- Scope: ZImage editor toolbar.
- Notes: Copy settings and Paste settings sit to the right of Push tone. Copy keeps Tone and Geometry. Paste applies them in one history step and leaves crop and object removal unchanged. Paste stays disabled until a copy has been made. The helper was not changed.

## 2026-11-06 — Double-click resets a slider to the middle

- Status: done
- Scope: ZImage editor Tone and Geometry panels.
- Notes: Double-clicking a slider knob returns it to the middle of its track. Temperature, Dehaze, k1, and k2 stay where they are. The helper was not changed.

## 2026-11-06 — Crop rectangle stays visible

- Status: done
- Scope: ZImage editor canvas.
- Notes: The crop rectangle and its handles draw on the canvas, over the image. Select outlines the whole image. Dragging a corner or the middle of a side changes that edge. Clicking Select again leaves Select. Crop still waits for a rectangle at least 2 pixels on each side. The helper was not changed.

## 2026-11-06 — Select and Crop on the image

- Status: done
- Scope: ZImage editor canvas.
- Notes: Select, Crop, and Export sit at the right edge of the image area, to the right of Folder and Image. Select drags a rectangle. Corners and the middle of each side resize it. Crop stays disabled until that rectangle is at least 2 pixels on each side, then crops in one history step named Crop. The helper was not changed.

## 2026-11-06 — Last folder comes back on launch

- Status: done
- Scope: ZImage editor folder tree.
- Notes: Open Folder and the folder selected in that tree are stored as bookmarks. The next launch shows that tree and that folder. A folder that cannot be opened leaves the tree empty. Opening a file at launch still shows that file. The helper was not changed.

## 2026-11-06 — Folder previews are 250 pixels

- Status: done
- Scope: ZImage editor folder previews.
- Notes: Folder-view JPEGs have a long edge of at most 250 px. The JPEG quality stays 70%. The cache file name stays the hash of the source path. The library thumbnails stay at 512 px. The helper was not changed.

## 2026-11-06 — Cache menu, Export on the Image tab, Sub-folder

- Status: done
- Scope: ZImage editor toolbar and folder previews.
- Notes: A three-bar menu to the left of Open File contains Cache, with Set Cache Size, View Cache, and Clear Cache. The preview cap defaults to 200 MB and is remembered. Quit and choosing another folder leave the preview files in place. Clear Cache deletes them. Export is to the right of the Folder and Image selector and shows only while Image is selected. The checkbox label is Sub-folder. The helper was not changed.

## 2026-11-06 — Sub lists subfolder images and videos in the Folder view

- Status: done
- Scope: ZImage editor folder grid.
- Notes: Sub searches subfolders for images and videos and shows them in the Folder view. Names from a subfolder include the relative path. The folder tree stays directories only. The helper was not changed.

## 2026-11-06 — Undo, Redo, and Push tone sit above Tone

- Status: done
- Scope: ZImage editor toolbar.
- Notes: Undo, Redo, and Push tone are in the right 320 points of the toolbar, above the Tone panel. Open File, Open Folder, and Export stay on the left. The helper was not changed.

## 2026-11-06 — Sub scans the folder tree for images and videos

- Status: done
- Scope: ZImage editor folder tree.
- Notes: Sub sits to the left of its checkbox, which sits to the left of View. Checked, the folder tree walks subfolders and lists the images and videos in them. Unchecked, the tree stays directories only. The Folder grid stays one directory level. The helper was not changed.

## 2026-11-06 — Folder grid keeps its scroll position

- Status: done
- Scope: ZImage editor folder grid.
- Notes: The Folder tab stays mounted while the Image tab is showing. Its scroll offset is remembered per folder and applied again when the Folder tab returns, so the grid does not jump to the top. The helper was not changed.

## 2026-11-06 — Folder view shows videos with the stills

- Status: done
- Scope: ZImage editor folder grid.
- Notes: The Folder tab lists video files in the selected folder beside the stills. A double-click on a video opens QuickTime Player and leaves the grid in place. The video menu leads with Open with QuickTime Player, then Show in Finder, then Open With. Open With lists video players, with QuickTime Player first. A still still opens on the Image tab. The helper was not changed.

## 2026-11-06 — Eight-point top inset on the inspector panels

- Status: done
- Scope: ZImage editor inspectors.
- Notes: Tone, Geometry, Eyedropper, and History use an 8-point top inset. The side insets stay 16. Tone, Geometry, and Eyedropper keep the 8-point bottom inset. History keeps a 16-point bottom inset. The helper was not changed.

## 2026-11-06 — Shorter bottom edge on the adjustment panels

- Status: done
- Scope: ZImage editor inspectors.
- Notes: The bottom inset of Tone, Geometry, and Eyedropper is 8 points, half of the previous 16. The drag strip under each of those panels is 4 points, half of the previous 8. Empty space under the controls is halved once and then left alone, so a later drag keeps the height the user sets. Top and side insets stay 16. The helper was not changed.

## 2026-11-06 — Slider names sit beside the sliders, and Hand zooms with Command

- Status: done
- Scope: ZImage editor inspectors and canvas.
- Notes: Each Tone and Geometry field name is on the same line as its slider, right-aligned in a 108-point column, with the readout after the slider. With Hand selected, Command-click zooms in and Command-Option-click zooms out. Option is the key to the right of the right-hand Command key. A click without Command still pans. The Zoom tool is unchanged. The helper was not changed.

## 2026-11-06 — Tone and Geometry sliders are shorter again

- Status: done
- Scope: ZImage editor inspectors.
- Notes: Tone and Geometry sliders draw at 56% of the system height, which is another 20% off the previous 70%. The gap between those rows is 5.6 points. Rotate, the corner-pin switch, the lens menu, the panel titles, and the Horizon button keep their normal size and font. Eyedropper and History are unchanged. The helper was not changed.

## 2026-11-06 — Tone and Geometry controls are shorter

- Status: done
- Scope: ZImage editor inspectors.
- Notes: Sliders, the rotate buttons, the corner-pin switch, and the lens menu in Tone and Geometry draw at 70% of the system control height. The gap between those controls is 7 points. Labels stay at 13 points. Eyedropper and History are unchanged. The helper was not changed.

## 2026-11-05 — Inspector panels drag

- Status: done
- Scope: ZImage editor inspectors.
- Notes: The lines between Tone, Geometry, Eyedropper, and History drag. Dragging a line moves every line below it. The panel above the line changes height, the panels under that line keep their heights, and History takes the change. Each adjustment panel stays at least 96 points and scrolls. History stays at least 80 points. Heights are stored as `ZImage.inspectorToneHeight`, `ZImage.inspectorGeometryHeight`, and `ZImage.inspectorEyedropperHeight`. The helper was not changed.

## 2026-11-05 — Horizon and Eyedropper sit on their panels

- Status: done
- Scope: ZImage editor inspectors.
- Notes: Horizon is at the top right of the Geometry panel. Eyedropper is at the top right of the Eyedropper panel. Both still choose the canvas tool. The image toolbar keeps Hand, Zoom, and Remove object. The helper was not changed.

## 2026-11-05 — Folder stills have a right-click menu

- Status: done
- Scope: ZImage editor folder grid.
- Notes: A still in the Folder tab has Edit Image, Show in Finder, and Open In. Edit Image opens that still on the Image tab. Open In lists the applications that can open the file, with ZImage first. Choosing ZImage edits it in this window. The last menu line is the file size in decimal megabytes, such as 2.5 MB. The helper was not changed.

## 2026-11-05 — The editor has a folder tree and two center tabs

- Status: done
- Scope: ZImage editor folder browser.
- Notes: Open Folder roots a directory tree on the left. The tree lists folders only, one level at a time. The Folder tab shows stills in the selected folder and does not walk into subfolders. Double-clicking a still opens it on the Image tab. The tree width drags and is remembered. The helper was not changed.

## 2026-11-05 — The folder column can be dragged wider

- Status: done
- Scope: ZImage Library sidebar.
- Notes: The line between the folder list and the grid drags. The column starts at 230 points and stays where it is left, between 180 and 720, leaving room for the grid. The helper was not changed.

## 2026-11-05 — Library finds the helper after the sandbox comes off

- Status: done
- Scope: ZImage Library launch.
- Notes: The helper at 192.168.1.147 answered health. The unsandboxed app reads a different preferences file, so the saved host and folder bookmark were left behind in the sandbox container and the window said Helper offline. Launch copies those two values across when the new file does not have them. The helper was not restarted.

## 2026-11-05 — Sandbox is off

- Status: done
- Scope: ZImage and ZImage Library.
- Notes: Both apps were sandboxed, so a new build asked for file access again. The sandbox entitlement is gone. The shared keychain group stays, so the helper pin and token still pass between the two apps. A folder bookmark falls back to a plain bookmark when a security-scoped one cannot be made.

## 2026-11-05 — Skin presets use measured face color

- Status: done
- Scope: ZImage editor skin eyedropper.
- Notes: The seven presets were the Monk Skin Tone cards. Those cards have almost no redness and very little yellow, so the grade pulled photographs blue. The targets are now measured facial a* and b*. The swatches are the sRGB of those Lab colors. Labels and preset ids are unchanged. Lightness is still not painted onto the photo.

## 2026-11-05 — Library actions sit behind a three-bar menu

- Status: done
- Scope: ZImage Library top row.
- Notes: A three-bar menu is at the left of the content row. Choose Library Base Folder and Pair with Helper are items in that menu. Open in ZImage, Events, and Reorganize stay as short buttons and sit on the right. The title bar and its close, minimize, and zoom buttons stay. The helper binary was not replaced.

## 2026-11-05 — The folder on screen gets previews first

- Status: done
- Scope: ZImage Library grid.
- Notes: A still on the current page with no preview is reduced on the Mac, one file at a time, and stored with the helper. That page is the folder being displayed. The helper's own queue is still oldest-first and was not replaced. Switching folders starts this pass on the new page. The helper binary was not replaced.

## 2026-11-05 — A folder click keeps the Videos tab

- Status: done
- Scope: ZImage Library folder tree.
- Notes: Choosing a folder while Videos is selected stays on Videos and reloads that folder’s movies. Photos stays on Photos. Review and Duplicates still move to Photos. The helper binary was not replaced.

## 2026-11-05 — Videos uses the Photos display folder

- Status: done
- Scope: ZImage Library Photos and Videos grids.
- Notes: Videos has the Display Folder button. Photos and Videos share one folder. Changing it on either tab changes the folder line and the files listed on both. The helper binary was not replaced.

## 2026-11-05 — Folder tree under the library tabs

- Status: done
- Scope: ZImage Library sidebar.
- Notes: Below Photos, Videos, Review, and Duplicates, the sidebar lists the folders under Photos. The rows use a disclosure chevron and a folder icon, in the same arrangement as the EditForth file list. The tree lists directories only and loads one level when a folder opens, so it does not walk every file on the share. Choosing a folder switches to Photos and shows that folder. The chevron opens and closes a row. Choose Library Base Folder opens the panel on the current base folder. The helper binary was not replaced.

## 2026-11-05 — Photos tab shows one folder

- Status: done
- Scope: ZImage Library window and Photos grid.
- Notes: The top button is Choose Library Base Folder. It still stores the PhotoVideoAudio share and does not change the grid. The Photos tab has Display Folder on the same line as the folder being shown. That starts as Photos. A chosen folder must be Photos or a folder inside it. The grid asks the helper for paths containing that folder, with a trailing slash so Photos/2026 does not include Photos/20260. The first 200 matches are shown. The close, minimize, and zoom buttons are back: they live in the title bar, and hiding that bar had removed them. The short action buttons stay in the content row. The helper binary was not replaced.

## 2026-11-05 — Keep the event name already written on the folder

- Status: done
- Scope: Reorganize destinations. Photos/2026 names restored on disk.
- Notes: A plan of `Photos/2026` copied 24 files out of `2026-03-19 1970s Debbie portrait`, `2026-03-20 - 1970s scans`, and `2026-09-23 Bartlett Home Coming` into a folder named `event` under the same three days. The Events list stayed empty because events are written at helper startup, and that pass had not run after those dates were stored. The planner now keeps the words after a leading `YYYY-MM-DD` in the folder name, and it leaves a file where it is when the stored event folder is only the hyphenated form of that same name. A review bucket of two hex digits still plans to `event`. The 24 files are back in `Photos/2026/2026-03-19/1970s Debbie portrait`, `Photos/2026/2026-03-20/1970s scans`, and `Photos/2026/2026-09-23/Bartlett Home Coming`. The empty `event` directories and the empty combined folders were removed. The catalog still lists the `event` paths until the helper restarts and relinks. After the user stopped the DSM task, health at `https://192.168.1.147:8742` was connection refused and the ARM64 binary was copied to `PhotoVideoAudio/.zimage/bin/zimage-helper` (17,762,215 bytes, mode 0700, BuildID sha1 `fe0327157e1743cacb1222332ba078f599224dc8`). The user started the task. Health is ok, pid 11314, RSS about 67 MB. The startup pass is still reconciling the cache. The 24 catalog rows still say `event`, and `GET /v1/events` is still empty. Those update after cache reconcile, relink, the Photos walk, and the organize pass. Plan was not sent. Start was not sent.

## 2026-11-05 — Counting line advances every 2 seconds

- Status: done
- Scope: Reorganize panel clock. Helper plan `seen` count in source.
- Notes: The panel’s counting line advances by 2 seconds on each status check while a plan is open. When the helper sends `counting` and `seen`, that line becomes the number of files looked at, and Move, Already placed, Park, and Leave refresh from that same check. The running NAS helper does not send those fields, so the four counts still appear when the plan is saved. A new ARM64 binary is built and is not copied. Nothing was copied. Start was not sent.

## 2026-11-05 — Reorganize status says Counting

- Status: done
- Scope: Reorganize panel. Helper plan progress in source.
- Notes: While a plan is running, the panel says Counting and checks the helper every 2 seconds. The four counts show when the helper marks the status `counting`, and they refresh on that check. The Cache line is gone. The “plan request waited 10 seconds” line is gone. The helper source publishes Move, Already placed, Park, and Leave as each folder is counted. That binary is not on the NAS. The running helper still commits the counts at the end of the plan, so those four numbers stay hidden until the plan is saved. Nothing was copied. The helper was not replaced.

## 2026-11-05 — Trim lives on the Duplicates tab

- Status: done
- Scope: Library Duplicates tab. Helper `GET /v1/duplicates?found=1`.
- Notes: The toolbar Trim button is gone. Find duplicates, Start, Pause, and Continue are on the Duplicates tab. The list is copies already in `Photos/_Duplicates`, so it stays empty until copies are gathered. Find asks for matching groups. The helper source lists groups of two or more that are still in the library. That query is not in the NAS binary, so the running helper still returns the store. An empty Find then says how many groups are ready and that Start gathers them. Nothing was copied. The helper binary was not replaced.

## 2026-11-05 — A typed calendar day is saved

- Status: done
- Scope: Set date in the library date panel.
- Notes: The field asks for `YYYY-MM-DD`. The helper accepted a four-digit year or an RFC3339 timestamp and answered `{"error":"date"}` for `2010-07-17`. The panel then said the date was not saved. A live post of that day for `SDC13577.MP4` returned HTTP 400 and left `captureTime` null. The library now sends a calendar day as midnight UTC, which the running helper already accepts. The helper source also accepts `YYYY-MM-DD`. That binary is not on the NAS. Nothing was copied.

## 2026-11-05 — A video uses the date closest to the file

- Status: done
- Scope: Video dates in the library grid and the date panel. Helper path dating.
- Notes: The Videos tab showed no date because the catalog capture is empty. `SDC13577.MP4` under `Photos/2010/20100714_27 Minnisota trip/20100717_100SSCAM day 4/` is phase `discovered`, confidence 0, and `captureTime` null. The day folder closest to the file is 2010-07-17. The movie header in the last 1 MB says container created 2010-07-17 14:21:17 UTC, duration 5.6 s, 1280 × 720, video codec `avc1`, audio codec `mp4a`. Plan and Assign now keep the path date closest to the file. The video grid shows that path day when the catalog day is empty. Selecting a video shows the path date and those movie-header fields. The reader does not decode frames. The helper binary on the NAS was not replaced. Nothing was copied.

## 2026-11-05 — Review plan is saved and not started

- Status: done
- Scope: Dry-run plan of `Photos/_Review` on the new helper. No copy.
- Notes: The user started the helper after the binary replace. Health was ok. `POST /v1/reorg/plan` with prefix `Photos/_Review` returned HTTP 200: Move 903, Already placed 1, Park 453, Leave 0. Status stayed `plan_ready`, phase `Photos/_Review`, safe to reboot. A catalog page of that prefix is 1,357 files, all still under `Photos/_Review`. 903 have a placing date (874 `exif_original`, 15 `exif_datetime`, 8 `filename`, 6 `exif_digitized`). 454 have confidence 0. `IMG_6462.HEIC` is `2025-01-01T09:50:17-06:00`, source `exif_original`, confidence 0.95, and it is still at `Photos/_Review/Undated/e0/`. Start was not sent. Nothing was copied. Park rows stay inside `Photos/_Review/Undated` and can change two-letter buckets. The 1964 file outside this prefix is not in the plan.

## 2026-11-05 — Helper binary replaced while stopped

- Status: done
- Scope: NAS helper binary.
- Notes: The user stopped the helper. Port 8742 was refusing connections and `helper.lock` was free. The new static ARM64 binary is at `PhotoVideoAudio/.zimage/bin/zimage-helper`, 17,754,882 bytes, mode 0700, BuildID sha1 `3cd13d8cd585a3b6c5d402845cb317fcbf0fc600`. It replaces BuildID `37e12f1aee2b70f5f8a5d2f25795228ed2307b28`. This binary reads a date in the filename and a HEIC Exif item while planning, and it can answer reorg status during a count. The user started it afterward. The Review plan entry above is that run.

## 2026-11-05 — Review list is readable and shows the file

- Status: done
- Scope: Library sidebar, Review list, and the date panel. HEIC header dates.
- Notes: The sidebar and the Review list were black ink on the system blue. Both lists, and the Events list, now use a light pastel blue, including the selected row. A Review click shows the stored preview, the catalog path, date, source, and confidence, and the DateTime tags ImageIO can read from the file header. The helper's event list is empty: zero rows. Events are built only from photos that already have a capture date. `IMG_6462.HEIC` in Review has header DateTimeOriginal `2025:01:01 09:50:17`. The helper now reads that Exif item without decoding the picture, and a plan of a folder reads it when the catalog date does not already place the file. Nothing was copied. The helper on the NAS was not replaced, so those dates are not in the catalog until that binary is updated.

## 2026-11-05 — Plan uses a date in the filename

- Status: done
- Scope: Reorganize plan. A blank catalog date still uses a full date written in the filename.
- Notes: The Photos/1974 run parked 1,349 files in `Photos/_Review/Undated` because each row had no stored capture date. Review shows names such as `Syntek_USB Camera_1964-11-24_3725959643136.jpg`. That form already scores 0.80. Plan was reading only the stored date, which was empty. Plan now places the file from the filename and stores that date. A name with no date stays in Review. A stored date that already places the file is left as it is. Nothing was copied. The helper on the NAS was not replaced, so the files already in Undated stay there until that binary is updated and Review is planned again.

## 2026-11-05 — Reorg count status is the helper state

- Status: done
- Scope: Reorganize status. The panel says a count is running only when the helper reports `runState` planning.
- Notes: Plan sets `job_state.run_state` to planning before the count, then holds the read connection for the whole scan. Status now reads that row on a separate watch connection, so the answer is planning while the count runs. The panel no longer says the helper may be counting. A missed status check says it got no answer. The helper binary on the NAS was not replaced, so the running helper still cannot answer status during a count.

## 2026-11-05 — Reorg status check wording

- Status: done
- Scope: Reorganize panel. A missed status poll names the reason, and a saved plan with every count at zero says the catalog has no files there.
- Notes: `Photos/Scans` is a saved plan with Move, Already placed, Park, and Leave at 0. The folder has 34 files on disk and no catalog rows. The status-check sentence is the Mac poll giving up after 10 seconds while the helper is busy. It is not a rejected folder. The helper was not replaced.

## 2026-11-05 — Reorg status line

- Status: done
- Scope: Reorganize panel. The step, the error, and the next press are on screen.
- Notes: The reboot lamp is unchanged. A second line names the step: counting, plan ready, copying, pause, recovery, or not enough free space. Changing the prefix hides Move, Already placed, Park, and Leave and says to press Plan. Start is not sent until that folder has a saved plan. A refused plan names the helper's reason. A 10-second wait says the helper may still be counting and the panel keeps checking. Start says a copy is starting, then that files are being copied. The helper was not replaced.

## 2026-11-05 — Reorg folder picker

- Status: done
- Scope: Reorganize prefix. Choose Folder fills the prefix from an existing folder under Photos.
- Notes: The picker opens at Photos on the share. Photos, and a folder inside it, become the prefix. The share root, a folder outside Photos, and Photos/_Duplicates stay out. Choosing a folder does not plan or copy. Plan still writes the dry run, and Start still uses the last Plan.

## 2026-11-05 — Videos dated in Photos

- Status: done
- Scope: Library sidebar and the reorg date plan for video files.
- Notes: Video extensions are `reorg_policy = move`. A later inventory walk updates a video row that is still `leave`. The container creation time, when present in the first or last 1 MB, dates the file. The plan keeps the destination under Photos. Movies and Video stay out of this step. The sidebar is Photos, Videos, Review, and Duplicates. Videos are ordered by capture day and show that day. A double-click opens QuickTime Player. Open With lists the other players, with QuickTime Player first. PDF stays leave. `go test ./...` in `Helper` passed. The ZImage Library scheme built. The ZImage scheme tests compiled and did not launch because ZImage was already open. The running helper was not replaced.

## 2026-11-05 — Helper listens before the cache walk

- Status: done
- Scope: Startup. The port opens before the cache ledger records existing previews.
- Notes: The first PR 21 start rewrote each preview and left port 8742 closed. Reconcile now records a preview's size and does not read or rewrite the file. The listener opens before that walk, and the photo walk waits until the ledger pass finishes. `go test ./...` in `Helper` passed. The user stopped the helper. The new binary is `PhotoVideoAudio/.zimage/bin/zimage-helper` (17,743,512 bytes, mode 0700, BuildID sha1 `37e12f1aee2b70f5f8a5d2f25795228ed2307b28`). Health was connection refused after the copy. The DSM task was not started.

## 2026-11-05 — Helper binary on the NAS

- Status: done
- Scope: Copy the PR 21 helper after the user stopped the process.
- Notes: Health at `192.168.1.147:8742` was connection refused. The log had stopped on `inventory_commit`. The static ARM64 binary was copied to `PhotoVideoAudio/.zimage/bin/zimage-helper` (17,741,756 bytes, mode 0700, BuildID sha1 `530a438e6c0b03e3bebcdedc6bc058d3816c0799`). `config.yaml` was left in place. The DSM task was not started. Reorg, trim, and purge stay idle until Start or a confirmation.

## 2026-11-05 — Duplicates browser

- Status: done
- Scope: Pass 2 PR 21. Duplicates list, restore, pin, and permanent delete.
- Notes: The sidebar is Photos, Review, and Duplicates. The store path stays `Photos/_Duplicates`. The grid uses the same preview slider and one helper JPEG per file. Changing the slider does not request another thumbnail. The Delete key does not purge. Delete one file asks for that filename and sends `confirmFilename`. Delete all duplicates sends a body only when the typed text is DELETE. Restore pins the file beside the keeper, or in the old folder, or under `Photos/_Review/Undated/`. Pin and clear pin are the same endpoint. A manual move creates a group of one when the file had none. A second trim can reuse a purged store filename, and the keeper path stays. `go test ./...` in `Helper` passed. The ZImage Library scheme built. DuplicatesBrowserTests, HelperClientTests, LibraryGridTests, and ReviewListTests passed (28 tests, 0 failures). Reorg, trim, and purge stay idle until Start or a confirmation. The NAS binary is still the PR 16 helper. Copy a new helper only after the user stops the process and asks.

## 2026-11-05 — Trim execution

- Status: done
- Scope: Pass 2 PR 20. Trim's own job, keeper moves, and purge recovery.
- Notes: `POST /v1/trim/start` plans eligible groups and copies one file at a time. It returns 409 `{"error":"busy"}` while reorg is planning, running, pause requested, or recovering, and it does not write the reorg pause flag. The sharp 1000×1000 file stays in the event folder as `is_keeper`. An equal-score 4000×4000 file and a byte-identical copy move under `Photos/_Duplicates/<group-uid>/` with `placement = duplicates`. A group with any null `detail_score` stays put. Pause during copying leaves the trim lamp false and leaves the reorg bit unchanged. A `purge_planned` row and a `manual_duplicate` row in `copying` clear the combined line. Purge recovery unlinks only a `Photos/_Duplicates/` path. A purge row aimed at `Photos/1999/keep.jpg` is marked `failed` and that file remains. ZImage Library has a Trim panel with Start, Pause, Continue, and the trim lamp. Opening it does not plan or copy. The sidebar stays Photos and Review. `go test ./...` in `Helper` passed. The ZImage Library scheme built, and HelperClientTests passed (11 tests, 0 failures). Reorg, trim, and purge stay idle until Start or a confirmation. The NAS binary is still the PR 16 helper. Copy a new helper only after the user stops the process and asks.

## 2026-11-05 — Cache ledger and relink

- Status: done
- Scope: Pass 2 PR 19. Cache ledger, eviction, scratch reconcile, and external-move relink.
- Notes: Thumbnail writes go through `cache_objects`. The operating target is 200 GB and the hard cap is 1 TB. A test cap of 1 MB evicts or refuses, and the summed ledger stays at or under that cap. Scratch above 64 MB is refused. Boot reconciliation lists `.zimage/cache` only: an unreferenced `cache/scratch` file is deleted, and a `move-backup` file named by a `source_detached` row stays. Relink runs before inventory. A renamed file keeps its uid, including a rename into `Photos/_Duplicates`, and the reorg plan does not move that file back out. A purged row is not a relink target. The Reorganize panel shows the helper cache byte count. `go test ./...` in `Helper` passed. Reorg, trim, and purge stay idle until Start or a confirmation. The NAS binary is still the PR 16 helper. Copy a new helper only after the user stops the process and asks.

## 2026-11-04 — Journaled reorg

- Status: done
- Scope: Pass 2 PR 18. Journaled moves, pause, resume, and reboot recovery.
- Notes: The helper plans under a Photos prefix and copies only after `POST /v1/reorg/start`. One file moves at a time: copy or reflink, hash, catalog update, `move-backup`, then unlink. Pause waits for the open file. A planned row leaves the reorg lamp safe. Boot finishes an open row before new work, and a pause flag does not start the next file. ZImage Library has a Reorganize panel with Plan, Start, Pause, Resume, and the helper's reorg lamp. `go test ./...` in `Helper` passed. The ZImage Library scheme built, and HelperClient, LibraryGrid, and ReviewList tests passed (24 tests, 0 failures). The NAS binary is still the PR 16 helper. Copy a new helper only after the user stops the process and asks. The reorg stays idle until Start.

## 2026-11-04 — Save edits on this Mac

- Status: done
- Scope: Editor Save. The photo folder is not written.
- Notes: File → Save writes the `.zimg` under Application Support `ZImage/edits/<blake3>.zimg`. The share folder, including `1964-11-24`, is left unchanged. Opening that photo again applies the file. Save As starts in that same edits folder and says the photo folder is read-only. Quit ZImage and run it again before using Save. The NAS helper is unchanged.

## 2026-11-04 — Keep each photo's edits with that photo

- Status: done
- Scope: Editor Save and reopen. No helper change.
- Notes: Switching away keeps that photo's tone and rotation in the session, and opening it again restores them. File → Save asks beside the photo instead of starting in Downloads. The `.zimg` is remembered by the photo's BLAKE3, so a later open applies it even if the file is not beside the photo. A `.zimg` named like the photo and sitting next to it is also applied. The copy already saved in Downloads is not linked. Save once more after rerunning ZImage. The new tests compiled. They did not run because ZImage was already open. The NAS helper is unchanged.

## 2026-11-04 — Reset edits when another photo opens

- Status: done
- Scope: Editor open. Tone, rotation, and the rest of the edit log. No helper change.
- Notes: Opening a second still, X3F, PDF, or a file that fails to open clears the previous tone and geometry, including quarter-turns, before the new picture is drawn. A saved `.zimg` still restores its own log. `OpenResetTests` and `PDFImportTests` passed. Rerun the ZImage scheme to pick this up. The NAS helper is unchanged.

## 2026-11-04 — Save edits and event rename

- Status: done
- Scope: PR 17. A catalog sidecar and a user event name. No photo moves and no helper deploy.
- Notes: `PUT /v1/edits/{uid}` stores a `.zimg` under `.zimage/edits/` with a 256 MB cap, a temp file, fsync, and rename. `GET` returns those bytes from a new helper process on the same root. Save As still writes `fileRef`. Save edits is absent from the File menu while the helper is down. `POST /v1/events/{uid}` sets `name_source` to user. A second naming pass keeps that name and rewrites a generated name. The photo bytes stay put. `go test ./...` in `Helper/` passed. `SaveEditsTests` passed. The NAS is still running the PR 16 binary, so these routes answer after the next deploy. Rerun ZImage Library, then ZImage. The library copies the helper address into the shared keychain. Open a catalog photo and use File → Save edits. The library Events button renames an event.

## 2026-11-04 — Open a saved .zimg in ZImage

- Status: done
- Scope: Finder handoff for ZImage RAW. No catalog change and no file moves.
- Notes: `ZImage-Info.plist` exports `com.Win32Forth.zimg` for the extension `zimg` and claims it with rank Owner. JPEG, PNG, HEIC, TIFF, camera RAW, PDF, and X3F stay rank Alternate. The built Debug app’s Info.plist has that claim. Launch Services reports the default handler as `com.Win32Forth.ZImage`. The document-type test did not launch because ZImage was already running.

## 2026-11-04 — Dating, groups, events, and detail scores

- Status: done
- Scope: PR 16. Planned destinations only. No bytes are moved.
- Notes: The helper now dates Photos, groups near-duplicates, names events, and scores detail. A typed date is confidence 1.0 and writes one planned journal row. Files under `Photos/_Review` and dates below 0.70 show in the library sidebar Review list, with a date panel beside it. The Mac checkpoints one `needs_mac` still at a time through ImageIO at 1024 px and ignores a missing route. `go test ./...` in `Helper/` passed. Scheme ZImage ran LibraryGridTests, ReviewListTests, and HelperClientTests with 0 failures. Scheme ZImageLibrary built. The user stopped the helper. Health at `192.168.1.147:8742` was connection refused. The new ARM64 binary was copied to `PhotoVideoAudio/.zimage/bin/zimage-helper` (17,342,689 bytes, mode 0700, BuildID sha1 `476bcfbc1cdbbe2ba77cc0d6e467525e900b4c6c`). The user ran the original DSM task. Health was ok, `libraryRootOK` true, RSS about 35 MB, pid 26409. The log showed `inventory_commit` and one `thumb_batch`, with no `thumb_failed` or `dating_failed`. Dating starts after this Photos walk finishes. Photos files are where they were.

## 2026-11-04 — Previews up to 32 million pixels

- Status: in progress
- Scope: Helper thumbnails for photos the grid marked No preview. No dating and no moves.
- Notes: The old rule refused a decode above 4 million pixels or a 16 MB pixel buffer, so a 1920×2560 JPEG (about 0.7 MB on disk) stayed empty. `Build` now decodes JPEG, PNG, GIF, and BMP up to 32 million pixels, which covers a 30 MP camera file such as 6720×4480. The file's byte size is not a limit. A frame above that, including the crafted 100 MP header, is still not decoded. Rows already marked `needs_mac` for a JPEG, PNG, GIF, or BMP at or under the ceiling are tried again. A decode that still fails is marked `failed` and is not retried. `go test` for thumb, inventory, and httpapi passed. `LibraryGridTests` passed. The user stopped the helper. The new ARM64 binary was copied to `PhotoVideoAudio/.zimage/bin/zimage-helper` (16,976,878 bytes, mode 0700, BuildID sha1 `31002b2321b433e0fd3ee5d6b496d3e042739a8e`). The user started the original task again. Health was ok, `libraryRootOK` true, RSS about 49 MB. The log showed `inventory_commit` and `thumb_batch`, with no `thumb_failed`. About 15,700 preview JPEGs were on disk, 1,358 of them written in the previous 10 minutes, and sampled files had a long edge of 512.

## 2026-11-04 — One ZImage window

- Status: done
- Scope: Open in ZImage. No dating and no moves.
- Notes: A second library photo was starting another ZImage process and another editor window. The editor scene is now one `Window`. File opens go to `ZImageAppDelegate` and replace the photo in that window. `LSMultipleInstancesProhibited` is set, and the library handoff targets the running ZImage.app with `createsNewApplicationInstance` false. `LSHandlerRank` stays Alternate. `HelperClientTests` ran 9 tests, with 0 failures, and the ZImage Library scheme built. Quit the extra ZImage copies, then run the ZImage scheme and the ZImage Library scheme again. The portrait that says No preview is still the 4-megapixel rule: 1920×2560 is about 4.9 million pixels and has no embedded preview, so the helper does not decode it. PR 16 stays waiting.

## 2026-11-04 — Library photo context menu

- Status: done
- Scope: ZImage Library cell menu. No dating and no moves.
- Notes: A right-click on a cell lists Open with ZImage, Show in Finder, then Open With. ZImage is also the first application in Open With. The last row is the original file’s size in decimal MB, from the file on the share, and it is not an action. A video keeps Open with ZImage disabled. `LibraryGridTests` ran 9 tests, with 0 failures. Run the ZImage Library scheme again to see the menu.

## 2026-11-04 — Open a library still in ZImage

- Status: done
- Scope: Open in ZImage. No dating and no moves.
- Notes: macOS showed “The application ZImage.app cannot open the specified document or url” because the editor did not declare a document type. `ZImage-Info.plist` now claims JPEG, PNG, HEIC, HEIF, TIFF, camera RAW, PDF, and X3F with `LSHandlerRank` Alternate, so ZImage is not the default app for those types. Launch Services delivers the file to `ZImageAppDelegate`, and the editor opens it with the existing security-scoped path. The user tried again and the still opened. `HelperClientTests` was re-run after removing a drain test that the live test host consumed. PR 16 stays waiting.

## 2026-11-04 — Library previews during inventory

- Status: done
- Scope: The blank squares in ZImage Library. No dating and no moves.
- Notes: Pairing worked. The grid's squares are the placeholder drawn when `thumbRel` is missing. The running helper had catalogued the first files and was still logging only `inventory_commit`. `.zimage/cache/thumbs` had no JPEGs, because `thumb.Apply` ran only after the whole Photos walk. The first page was 200 JPEGs: 171 at or under 4 megapixels, which `Build` can reduce, and 29 over 4 megapixels with no embedded preview, which stay `needs_mac`. A live 800×533 file produced a long edge of at most 512. A live 1920×2560 file returned `needs_mac` and was not fully decoded. `catalogPass` now writes up to 200 previews before the rest of the walk, and 8 more after each inventory commit. The library window says when previews are still being written, refreshes every 2 seconds until the visible page is resolved, and badges a finished oversized file "No preview". `go test` passed for thumb, inventory, and httpapi. `xcodebuild test` ran 82 tests, with 1 skipped and 0 failures. The user stopped the old helper from DSM. The new ARM64 binary was copied to `PhotoVideoAudio/.zimage/bin/zimage-helper` and the task was run again. The user then saw previews in ZImage Library. A check from the Mac showed health ok, `libraryRootOK` true, and 437 JPEGs under `.zimage/cache/thumbs`, while the walk was still logging `inventory_commit`. Files over 4 megapixels with no embedded preview stay empty. PR 16 stays waiting.

## 2026-11-04 — Library pairing

- Status: done
- Scope: The ZImage Library window can claim the helper. No dating and no moves.
- Notes: The helper was already running on the DS423. The library window stayed empty because it had no stored address or token. Pair with Helper reads `.zimage/PAIRING-TOKEN` from the chosen PhotoVideoAudio folder, resolves the share host to an IPv4 address, pins the certificate on first use, and calls `POST /v1/pair/claim`. The address and pin go in the keychain service "ZImage NAS Helper". `DS423._smb._tcp.local` is also looked up as `DS423.local` when the SMB name has no A record. The dial uses the IPv4 address. `xcodebuild test` ran 81 tests, with 1 skipped and 0 failures. Next step is PR 16, dating and detail, when the user asks.

## 2026-11-04 — Pass 2 PR 15: inventory and thumbnail browse

- Status: done
- Scope: PR 15. Walk `Photos`, write one JPEG per still, and show that JPEG in ZImage Library. No dating, no moves, and no deploy.
- Notes: The user asked to start PR 15 on 2026-11-04. `go test ./...` in `Helper` passed for config, db, httpapi, inventory, lockfile, pathsafe, and thumb. `xcodebuild test` ran 76 tests, with 1 skipped and 0 failures. A 20-file fixture, with one file under `Photos/_Duplicates/ab/`, `Thumbs.db`, and a file inside `.thumbnails/`, lists 18 rows from `GET /v1/assets`. The skipped names are absent. The duplicate's thumbnail is a JPEG whose long edge is at most 512. A crafted 100 MP header returns `needs_mac` and the test allocation stays under 64 MB. The library grid test uses a fake helper. Cell bytes come from `/v1/assets/{uid}/thumbnail`. Moving the preview slider from 80 pt to 480 pt does not request another thumbnail. A PDF item is handed to ZImage and opens the page picker. A `.mov` is badged Video and stays in the library. ZImage Library is `com.Win32Forth.ZImageLibrary`. It keeps an app-scoped bookmark for the share, shows the offline banner, and does not link libjxl or libwebp. The editor window is unchanged. Nothing was copied to the NAS, and `catalog.db` was not created from the Mac. Next step is PR 16, dating and detail, when the user asks.

## 2026-11-04 — Pass 2 PR 14: helper service and library client

- Status: done
- Scope: PR 14. Background Go helper, full catalog schema, authenticated IPv4 API, and the Mac client the library app will present. No inventory and no moves. The editor window is unchanged.
- Notes: The user asked for Pass 2 on 2026-11-04 and specified the split. The helper does the catalog work behind the scenes. A lightweight foreground app shows reduced images and hands one image to ZImage for larger viewing and processing. That app is ZImage Library. Its target is PR 15. `go test ./...` in `Helper` passed for config, db, httpapi, lockfile, and pathsafe. `xcodebuild test` ran 72 tests, with 1 skipped and 0 failures. The helper listens with `net.Listen("tcp4", "0.0.0.0:8742")`. SQLite is `modernc.org/sqlite` v1.61.1 with `CGO_ENABLED=0`. `job_state` is keyed by `job_kind`, with idle `reorg` and `trim` rows, and there is no `CHECK (id = 1)`. Health omits paths and tokens. Unauthenticated `GET /v1/assets` returns 401. Claim deletes `PAIRING-TOKEN`. The Mac stores the helper's IPv4 address with the SPKI SHA-256 pin in the keychain service "ZImage NAS Helper". A name, an IPv6 address, a changed host, or a changed pin is refused before a dial. The stale banner is "Helper offline. This grid is the last response and is not a saved catalog." It is not mounted on the editor. The sandbox entitlement `com.apple.security.network.client` is true. `com.apple.security.network.server` is absent. DSM Task Scheduler should start `PhotoVideoAudio/.zimage/bin/zimage-helper` at boot as a non-admin user, with `GOMEMLIMIT=160MiB`. Before `catalog.db` exists, on the NAS: `mkdir -p /volume1/BackupData/PhotoVideoAudio/.zimage/catalog` and `chattr +C /volume1/BackupData/PhotoVideoAudio/.zimage/catalog`. The helper does not run `chattr`. Cross-compile on the Mac with `cd Helper && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o zimage-helper ./cmd/zimage-helper`. Nothing was copied to the NAS. Next step is PR 15, the ZImage Library grid, when the user asks.

## 2026-11-04 — Pass 1 PR 13: linear DNG export

- Status: done
- Scope: PR 13. 16-bit uncompressed linear RGB DNG. No Adobe SDK. No helper.
- Notes: `xcodebuild test` ran 66 tests, with 1 skipped and 0 failures. The file is little-endian TIFF. `DNGVersion` is bytes 1, 4, 0, 0. The SubIFD is photometric interpretation 34892, 16 bits, 3 samples, and the test image is 32×24. ImageIO reads IFD 0 back at those dimensions. IFD 0 is a 16-bit RGB view of the same pixel strip, because ImageIO on this Mac does not decode photometric 34892. The panel says a 100 megapixel file is about 600 MB. The notice "This product includes DNG technology under license by Adobe." is in the writer and in `Acknowledgements.txt`. Pass 1 is complete. Pass 2 does not start until the user asks for it.

## 2026-11-04 — Pass 1 PR 12: WebP and JPEG XL

- Status: done
- Scope: PR 12. Vendored libwebp 1.6.0 and libjxl 0.12.0. Lossy and lossless WebP. JPEG XL at distance 1.0 or lossless, effort 7.
- Notes: The same 66-test run covers this PR. A 32×32 lossy WebP and a 32×32 JPEG XL each come back from their own decoder at 32×32. Lossless WebP matches the opaque RGBA buffer. Lossless JPEG XL matches the RGB buffer. WebP quality defaults to 80. libjxl is linked with highway 1.4.0, brotli 1.2, and little-cms2 2.19, copied into the app Frameworks folder. The JPEG sRGB red check from PR 11 still passes. Both formats are in the export panel. Next step is Pass 1 PR 13, linear DNG export.

## 2026-11-04 — Pass 1 PR 11: ImageIO and PDFKit export

- Status: done
- Scope: PR 11. JPEG, HEIC, TIFF, TIF, PNG, AVIF, JPEG 2000, PSD, OpenEXR, BMP, GIF, TGA, and one-page PDF. No WebP and no JPEG XL in this PR.
- Notes: `xcodebuild test` ran 61 tests, with 1 skipped and 0 failures. Each ImageIO exporter and PDFKit wrote a 32×32 gradient and read it back. `.tif` and `.tiff` open as `public.tiff`. A linear Display P3 red of `(0.5, 0, 0)` comes back from JPEG as an sRGB red channel between 0.65 and 0.85. JPEG 2000 quality 1.0 matches an 8-bit PNG byte. OpenEXR is 16-bit float. TGA is 8-bit. Default TIFF and PNG report depth 16. A long edge over 30,000 is refused for PSD and the message names TIFF and OpenEXR. An inpaint with no LaMa model throws and writes nothing. Export… has no shortcut. Next step is Pass 1 PR 12, WebP and JPEG XL.

## 2026-11-04 — Pass 1 PR 10: .zimg document

- Status: done
- Scope: PR 10. Versioned `.zimg` read and write. `fileRef` is the save-panel path. `catalogRef` and `embedded` exist for tests. Schema 1. No helper.
- Notes: `xcodebuild test` ran 52 tests, with 1 skipped and 0 failures. A `fileRef` with eight tone commands reloads, undoes six, redoes two, and matches `EditState`. The reloaded BLAKE3 matches the original bytes. The save-panel bytes contain no original. A `catalogRef` has no `base-original` section. An `embedded` document does. `ZImageTests/Fixtures/schema-v1-minimal.zimg` migrates through an injected schema-2 step. Schema 999 throws and the file bytes stay put. Empty BLAKE3 is `af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262`. File → Save is ⌘S and Save As is ⇧⌘S. The sandbox user-selected file entitlement is read-write. Next step is Pass 1 PR 11, ImageIO and PDFKit export. Pass 2 does not start until the user asks for it.

## 2026-11-04 — Pass 1 PR 9: object removal

- Status: done
- Scope: PR 9. One click builds a mask. Vision instance mask, then a Lab flood fill. `InpaintOp` stays in `EditState.swift`. The LaMa weights are not in the repo.
- Notes: `xcodebuild test` ran 48 tests, with 1 skipped and 0 failures. A click on a synthetic patch produces a grayscale PNG whose bounding box contains the click and whose long edge is at most 1024. The color fallback's history title is "Remove object, color selection". Undo removes the command and the replayed state has no inpaint. `StubInpainter` blurs under the mask and leaves a far corner unchanged. The bundle has no `lama-big-coreml-v1` model, so the Core ML input test is skipped. Export of a document that contains an inpaint command throws "Object removal needs the LaMa model, and that model is not installed. Nothing was written." Planned model inputs stay at most 1024 on the interactive path and 2048 on export, and export tiles overlap by 128. `advimman/lama` is Apache-2.0. A later conversion can be added as `lama-big-coreml-v1.mlmodelc`. Next step is Pass 1 PR 10, the `.zimg` document. Pass 2 does not start until the user asks for it.

## 2026-11-04 — Pass 1 PR 8: eyedropper and skin presets

- Status: done
- Scope: PR 8. White and skin eyedroppers. Seven presets. `SkinGrade` stays in `EditState.swift`. Samples are taken after geometry and before tone.
- Notes: `xcodebuild test` ran 42 tests, and all passed. A linear patch `(0.5, 0.4, 0.3)` white-balances to within ΔE76 of 2 of neutral. Temperature and tint stay inside 2000…50000 K and −150…150. The search uses the pipeline's existing pair, neutral `(6500, 0)` and target `(temperature, tint)`. A patch at the first preset's a\* and b\*, graded toward preset `deep`, moves a\* and b\* toward that preset and keeps L\* within 1. Preset labels, in order, are Caucasian, Asian, Southeast Asian, Middle Eastern, Hispanic, South Asian, and African. The file stores the preset id. The keyboard shortcut E is on the menu only. Next step is Pass 1 PR 9, object removal. Pass 2 does not start until the user asks for it.

## 2026-11-04 — Pass 1 PR 7: geometry

- Status: done
- Scope: PR 7. Quarter-turns, horizon, keystone, corner pin, and the five lens profiles. `GeometryState` stays in `EditState.swift`.
- Notes: `xcodebuild test` ran 38 tests, and all passed. Keystone at vertical 1 keeps the center at `(0.5, 0.5)` and maps the top-left corner to `(-1/6, -1/6)` and the top-right to `(7/6, -1/6)`. One clockwise quarter-turn turns 40×16 into 16×40. The bitmap angle and `CIStraightenFilter` share a sign, so the horizon command writes the measured tilt back. An 18° line levels within half a degree. A 70° line takes one quarter-turn and levels within half a degree. Rotate clockwise, rotate counterclockwise, one vertical drag, a lens profile, and the horizon click each commit one `setGeometry`. Super-wide adapter, mild copies k1 −0.15 and k2 0.05. Undo restores the draft from the log. Identity geometry is not resampled. The entitlements file is unchanged: sandbox, app-scoped bookmarks, and user-selected read-only. Next step is Pass 1 PR 8, the eyedropper. Pass 2 does not start until the user asks for it.

## 2026-11-04 — Pass 1 PR 6: zoom

- Status: done
- Scope: PR 6. Logarithmic zoom from 0.1× to 4×. 1× is one image pixel per screen point. Click multiplies by √2. Option-click divides by √2. Fit may drop the slider floor to 0.05. ⌘0 fits and ⌘1 sets 1×, both on the menu. The hand tool is the default. A zoom past 1.25× schedules a tile request after 150 ms. Zoom does not rebuild the proxy.
- Notes: `xcodebuild test` ran 33 tests, and all passed, together with PR 5. Clamp holds 0.1× and 4×. One click lands on √2 and option-click returns to 1×. Fitting a 20,000 px image in a 500 pt view sets the magnification and the slider minimum to 0.05. Twenty zoom changes with tone held constant leave `proxyRenderCount` unchanged and leave `tileRequestCount` at 1. The non-test signature still has the sandbox, app-scoped bookmarks, and user-selected read-only. Next step is Pass 1 PR 7, geometry. Pass 2 does not start until the user asks for it.

## 2026-11-04 — Pass 1 PR 5: X3F preview and PDF page import

- Status: done
- Scope: PR 5. A file whose header is not `FOVb` reports "Not an X3F file." A real X3F opens from the largest embedded JPEG at most 8 MB, with `decode_support = preview_only` and the banner "Sigma X3F preview only. Full Foveon decode is not available." PDF open shows the page picker on page 1. The chosen page is the edit base, long edge at most 8192. The folder grid still does not list X3F or PDF.
- Notes: `not-x3f.bin` throws that exact error. A synthetic `FOVb` file with a small JPEG and a larger `SECi` JPEG opens the larger one through the ImageIO thumbnail path, reads under the 64 MB budget, and the canvas shows the banner. A two-page PDF stays at two pages until Open page, which records page 1 at 200×100. A 12,000×3,000 media box renders with a long edge above 8,000 and at most 8,192. `ProxyRenderer` still rejects `.x3f` and `.pdf` on its own. The same 33-test run covers this PR. Next step is Pass 1 PR 6, zoom.

## 2026-11-04 — Pass 1 PR 4: folder browser and preview size

- Status: done
- Scope: PR 4. File → Open Folder lists one directory level. Grid previews are one JPEG per file, long edge at most 512, under `temporaryDirectory/ZImage/folder-previews/`, LRU 200 MB, wiped on quit. The preview-size slider is 80–480 pt, default 160, label "Preview size". No editor zoom in this PR.
- Notes: `xcodebuild test` ran 22 tests, and all passed. A fixture folder lists `child`, `a.jpg`, `b.jpg`, and `wide.jpg`. `nested.jpg`, a text file, a PDF, and an X3F are not listed. Each image gets one JPEG, the wide preview's long edge is above 400 and at most 512, and a second ensure keeps the same bytes. Moving the preview size from 80 pt to 480 pt does not change those files. The LRU test keeps the newest JPEG when the cap is 1 byte and wipe removes the directory. Choosing a thumbnail opens it through the PR 2 proxy path, and Back returns to that folder's grid. The edit log is left in place. A non-test signature still has the sandbox, app-scoped bookmarks, and user-selected read-only, plus the debug `get-task-allow` entitlement. The window title is ZImage. The accessibility tree showed "This folder", "No folder open", Canvas "No image", and Tone "Exposure". File → Open File… is ⌘O. File → Open Folder… has no shortcut. Screen capture was not used. Next step is Pass 1 PR 5, X3F preview and PDF page import. Pass 2 does not start until the user asks for it.

## 2026-11-04 — Pass 1 PR 3: tone and dehaze

- Status: done
- Scope: PR 3. Tone sliders and the dehaze kernel. `ToneState` stays in `EditState.swift`. No folder grid, no eyedropper, no geometry.
- Notes: `xcodebuild test` ran 19 tests, and all passed. Contrast slider 0 writes filter input 1, saturation slider 0 writes 1, and highlight slider 0 writes `inputHighlightAmount` 1. Whites and blacks at 0 leave the shared `CIToneCurve` on the diagonal. The default `ToneState` matches a render with no tone filters on a mid-gray patch. The JPEG fixture rendered at exposure 0 and at +1 EV produces two different downsampled hashes, and the exposure 0 hash matches the unfiltered image. Six exposure drags commit six commands; six undos return the identity state. Two keyboard nudges of contrast commit one command after 400 ms of idle. The dehaze kernel's ROI is the output tile. On a 64×64 image the input region stays within that tile, dehaze 0 copies the input, and dehaze 1 darkens the patch. The proxy context working format is `CIFormat.RGBAh` in extended linear Display P3. The inspector lists Exposure through Tint, with temperature at 6500 K. The canvas still says "No image", and the history list still says "No edits yet", until a slider gesture ends. Next step is Pass 1 PR 4, the folder browser and preview size. Pass 2 does not start until the user asks for it.

## 2026-11-04 — Pass 1 PR 2: open one still and build the proxy

- Status: done
- Scope: PR 2. File → Open File opens one still from anywhere the Mac can read. JPEG, PNG, HEIC, and TIFF use an ImageIO thumbnail. Camera RAW uses `CIRAWFilter` with `scaleFactor`. The proxy long edge is at most 2560. No tone sliders, no folder grid, no X3F walker, and no PDF page picker.
- Notes: `xcodebuild test` ran 9 tests, and all passed. The 64×40 JPEG fixture uses the thumbnail entry point, records no scale factor, and stays 64×40. A generated 4000×1000 JPEG thumbnail has a long edge of at most 2560 and greater than 2000. PNG and TIFF use the same thumbnail entry point. The 32×24 `.dng` fixture uses `scaleFactor` at 1 and keeps a long edge of 32. A generated 3000×4 `.dng` applies `2560/3000` and lands above 2000 and at most 2560. That file is photometric RGB with a `.dng` extension, not a camera mosaic. The same layout at a few hundred rows is rejected by the RAW reader, so the cap is proven on a short strip. `.x3f` and `.pdf` are rejected as unsupported and produce no proxy. `ProxyRenderer` does not call `CGImageSourceCreateImageAtIndex`. A non-test signature contains the app sandbox, app-scoped bookmarks, and user-selected files read-only, plus the debug `get-task-allow` entitlement. It does not contain user-selected read-write. The built app opened a window titled ZImage. The accessibility tree showed "This folder", "No folder open", "No image", and "History". The Open File toolbar button's help is "Opens one still image from anywhere this Mac can read." The File menu has Open File… as ⌘O. Undo remains ⌘Z and Redo remains ⌘⇧Z. Screen capture was not used. Next step is Pass 1 PR 3, tone and dehaze. Pass 2 does not start until the user asks for it.

## 2026-11-04 — Pass 1 PR 1: macOS shell and parametric undo

- Status: done
- Scope: PR 1. Mac window, cream chrome, `#333333` canvas, history list, and the parametric command log. No image decoder.
- Notes: `SDKROOT` is `macosx`. The app sandbox is on and user-selected files stay read-only (`ZImage.entitlements`). A non-test build's signature contains those two entitlements plus the debug `get-task-allow` entitlement. `ZImageTests` hosts the app. On Xcode 27.0 (27A5218g), `xcodebuild test` ran `HistoryLogTests`: 120 commits compact to one keyframe plus the last six commands, cursor is 7, six undos and six redos restore that cursor, and the encoded log round-trips with an identity `setTone`, an identity `setGeometry`, and an `addInpaint` whose mask is empty. A second test checks that a commit drops the redo tail. The built app opened a window titled ZImage. The accessibility tree showed "This folder", "No folder open", "Canvas", "History", and "No edits yet". One press of Push tone added one selected history row, enabled Undo, and left Redo disabled. The Edit menu has Undo as ⌘Z and Redo as ⌘⇧Z. `xcode-select` points at the Command Line Tools, so the build used `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`. Screen capture was not permitted, so the painted button titles were not read from a screenshot. Next step is Pass 1 PR 2, opening one file and building the proxy. Pass 2 does not start until Pass 1 is usable and the user asks for it.

## 2026-11-04 — Design revised: editor first

- Status: not started
- Scope: DESIGN.md (Draft). No application code yet.
- Notes: Design only. The Xcode project is still the Hello-world multiplatform template (`ZImage/ContentView.swift`, deployment target macOS 27.0). On 2026-11-04 `/Volumes/BackupData/PhotoVideoAudio` was listed read-only and nothing was modified. Duplicates Explorer's index was queried read-only (911,834 rows). ImageIO destination UTIs were measured on macOS 27.3. The plan is two passes and twenty-one PRs. Pass 1 is PR 1 through PR 13: the Mac editor opens a still image from anywhere the Mac can read, including X3F preview and a PDF page, views it, edits it, and stores a `.zimg` or an export, plus a local folder browser and a preview-size slider. Pass 1 does not include the helper. Pass 2 is PR 14 through PR 21: the Synology catalog, dating, journaled reorganization, Save edits, the cache ledger, detail-score keepers, optional Trim, and the duplicates store at `Photos/_Duplicates/`. The reorg places every copy and deletes nothing. Trim is a separate job the user starts, and it moves every unpinned active non-keeper. Permanent delete applies only to files already in that store, after confirmation, and leaves a tombstone path. Pass 2 does not start until the user asks for it after Pass 1 is usable. Next step is Pass 1 PR 1, the macOS shell and parametric edit log. It is not the helper. On 2026-11-04 the user confirmed both former open questions. Reorg scope is Photos only, which includes Trim and the duplicates store. The temporary preset labels are Caucasian, Asian, Southeast Asian, Middle Eastern, Hispanic, South Asian, and African. The file stores the preset id, not the display string. No open questions remain. The pass split and the duplicate system are decided.
