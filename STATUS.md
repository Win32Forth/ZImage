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

## 2026-11-21 — ZImager 1.8.5

- Status: done
- Scope: ZImager 1.8.5. Curve, Vignette, scroll zoom, Flatten Duplicate, folder-panel disclosure, Build previews, X3F open, and file rename. The helper source adds the X3F embedded preview and `POST /v1/files/rename`. The NAS binary on the share is that build.
- Notes: Marketing version 1.8.5 is on the ZImager target. The test target stays 1.0. `CURRENT_PROJECT_VERSION` stays 1. `.zimg` `appVersion` stays `1.0.0`. Curve sits between Tone and Color. RGB shapes the whole picture. Red, Green, and Blue shape one channel after that. Linear, Matte, Film Moody, Punch, and Lo-fi set the RGB curve. Drag a handle. Click the curve to add a point, up to eight. Double-click a middle handle to remove it. Double-click an end to put that corner back. Vignette sits under Touchup, with Amount, Midpoint, Roundness, Feather, X, and Y. Positive X moves the clear center right. Positive Y moves it up. Dragging the photograph moves it. The scroll wheel zooms around the pointer. Scroll up zooms in. Duplicate, on the Flatten dialog, writes a flattened TIFF beside the photograph. The name gains `-2`, then `-3`. The photograph and its edits stay. Each Folder-column panel folds from an arrow on its title. Preview is the title above the picture. Build previews sits under Merge two photos on Disk and on Server Photos. It builds a preview for each photo in the open folder that does not already have one. Videos are left out. A name filter has to be cleared first. Disk writes the folder-preview cache. Server stores the preview through the helper. An X3F cell uses the embedded preview. Opening an X3F develops the sensor image with the bundled CPU converter, x3fuse-core 0.5.0, denoising off, then edits that 2560 proxy. The color is the converter's sRGB, not Sigma Photo Pro. sd Quattro and sd Quattro H color-mode calibration is not in that converter. A missing converter, a file under 64 KB, or a failed sensor decode opens the embedded preview and says so. The helper does not run the converter. X3I files are not opened. `POST /v1/files/rename` keeps the catalog id after a file rename in the same folder and drops an edit-less extra row for the new name. Photos/_Removed, Photos/_Duplicates, and Photos/_Review are refused. The NAS binary is 18,022,007 bytes, mode 0700, BuildID sha1 `761983975506eb91b8213f1d7ab5e8e68696926e`. The Release archive is arm64, signed with the development certificate, and is not notarized. The disk image is `Releases/ZImager-1.8.5-macOS.dmg`, sha256 `9d96998fca3fadf75fcdb14ef6d1fe796d9b42644786f7cd164b1d343064a90b`. It contains ZImager.app and README.txt. It does not include the helper. Reorganize, Review, and Duplicates still do not work and can lose photos. Leave them alone.

## 2026-11-19 — ZImager 1.8.4

- Status: done
- Scope: ZImager 1.8.4. Folder rename, Organize, Clean, rotation that keeps repairs in place, and previews off the main thread. The helper source adds folder rename and catalog confirm. The NAS binary was not replaced for this release.
- Notes: Marketing version 1.8.4 is on the ZImager target. The test target stays 1.0. `CURRENT_PROJECT_VERSION` stays 1. `.zimg` `appVersion` stays `1.0.0`. Disk and Server reduce four photographs at a time, off the main thread. Disk previews stay in the temporary cache with a 200 MB cap. Server previews stay on the NAS. Server Folder view shows the still count as `(12345)`. Videos are left out of that number. Organize and Clean are on the Server Date panel. Organize asks first. Continue reads this page and the pages after it, and stops when a page neither moves a photo nor raises confidence. Yes reads this page. No leaves every file where it is. A photo with no date goes to Photos/_Review. A dated photo goes to Photos/YYYY/YYYY-MM-DD. A photo already in that year and day folder stays. When DateTimeOriginal, DateTimeDigitized, or DateTime matches that folder and catalog confidence is 0.00, confidence becomes 1.00. A moved photo that matches another file of the same size leaves a preview in Photos/_Duplicates. Clean deletes Thumbs.db, ehthumbs.db, desktop.ini, .DS_Store, and AppleDouble `._` files, then deletes a folder that has nothing else in it. Photos itself stays. A symbolic link is left in place. Right-click Rename on a folder keeps it in its parent. Photos and the three shelves keep their names. A folder under Photos is renamed on disk, then the helper rewrites catalog paths and keeps each file id, including videos. The Mac waits three minutes for that write. Rotate left or right keeps Vertical on the top and bottom edges on screen and Horizontal on the left and right. A crop, Spot, Scratch, or Red Eye repair made before that turn stays on the same pixels. The Release archive is arm64, signed with the development certificate, and is not notarized. The disk image is `Releases/ZImager-1.8.4-macOS.dmg`, sha256 `798c432d2f857b6b5319f0f72154fed3bb68f4591a0f15c1e136d7d27178d1cd`. It contains ZImager.app and README.txt. It does not include the helper. Reorganize, Review, and Duplicates still do not work and can lose photos. Leave them alone.

## 2026-11-19 — Folder rename waits for the catalog

- Status: done
- Scope: Mac folder rename. Helper source only. The running NAS binary was not replaced.
- Notes: `Photos/Debbie Grok` was still the directory on disk after the catalog paths had moved to `Photos/DebbieGrok`. Those rows are videos. The directory was renamed to `DebbieGrok`. It is the same directory, with 31 entries, and it is not a symbolic link. The Mac had been waiting 10 seconds. The helper can spend two minutes acquiring the catalog write, so the folder was put back while that write finished. The rename request now waits 3 minutes. A timed-out reply is asked once more. When that reply also does not arrive, the new directory stays and the notice says the catalog may still be catching up. A helper that cannot be reached still puts the folder back. Helper source treats a later try as success when the catalog is already under the new name, the old name has no rows, and the new directory is the one on disk. That source is not installed. Port 8742 was left running. Reorganize was not started. Quit ZImager and rerun the scheme before the next rename.

## 2026-11-19 — Helper binary with folder rename

- Status: done
- Scope: NAS helper binary. The DSM task was already stopped.
- Notes: Port 8742 was refusing connections. `go test ./...` in `Helper/` passed. The new static ARM64 binary is at `PhotoVideoAudio/.zimage/bin/zimage-helper`, 17,940,914 bytes, mode 0700, BuildID sha1 `8eba488895124fcdf7cfa4f517829db664d020c1`. It replaces BuildID `adfe145bf8205c87f69260729a53be4d30fd3056`. `config.yaml` was left in place. This binary adds `POST /v1/folders/rename`, which rewrites catalog paths for a folder the Mac has already renamed and keeps each photo's id. It does not move the directory and it does not write a journal row. Health was still connection refused after the copy. The DSM task was not started. Starting it begins the startup walk from the beginning. Reorganize was not started.

## 2026-11-19 — Rename a folder from the tree

- Status: done
- Scope: Disk and Server folder trees. Helper source gained `POST /v1/folders/rename`. The binary on the NAS was not replaced.
- Notes: Right-click a folder and choose Rename. The folder stays in its parent. Spaces inside the name stay. Photos, Photos/_Removed, Photos/_Duplicates, and Photos/_Review keep their names. A symbolic link is left in place. A Disk folder outside the library is renamed on disk. A folder under Photos is renamed on disk, then the helper rewrites each catalog path under that folder and keeps the photo id. Edits and previews stay with that id. The helper that is installed now has no rename route, so a Photos folder is put back and the notice says the catalog could not follow the new name. Replacing that binary is a separate step, and this session did not replace it. The ZImager scheme compiled. The new folder-rename tests passed. Quit ZImager and rerun the scheme.

## 2026-11-19 — Geometry follows a left or right rotation

- Status: done
- Scope: Editor Geometry, crop, and Spot, Scratch, and Red Eye. The helper is unchanged.
- Notes: Vertical still changes the top and bottom edges of the picture on screen, and Horizontal the left and right, after Rotate left or Rotate right. Keystone is applied after the quarter-turn. A crop made before that turn stays on the same part of the photograph. A Spot, Scratch, or Red Eye repair made before that turn stays on the pixels it repaired. Corner pins stay in the photograph's original frame. Quit ZImager and rerun the scheme.

## 2026-11-19 — Clean removes thumbnail cache files

- Status: done
- Scope: Server Folder view, Date panel. The helper is unchanged.
- Notes: Clean deletes Thumbs.db, ehthumbs.db, desktop.ini, .DS_Store, and AppleDouble `._` files, then deletes a folder that has nothing else in it. A photo or any other file keeps its folder. Photos itself stays. A symbolic link is left in place. `Photos/1980 Ansel Adams` stayed because `1980-7-22 Ansel Adams` held `Thumbs.db`. Quit ZImager and rerun the scheme.

## 2026-11-19 — Helper binary with catalog confirm

- Status: done
- Scope: NAS helper binary. The DSM task was already stopped.
- Notes: Port 8742 was refusing connections. `go test ./...` in `Helper/` passed. The new static ARM64 binary is at `PhotoVideoAudio/.zimage/bin/zimage-helper`, 17,934,888 bytes, mode 0700, BuildID sha1 `adfe145bf8205c87f69260729a53be4d30fd3056`. It replaces BuildID `f54dc04370799b6e495e6bff2742eb41548585ef`. `config.yaml` was left in place. This binary adds `POST /v1/assets/{uid}/confirm`, which sets catalog confidence to 1.00 when the file is already in its year-and-day folder and the stored confidence is 0.00. It does not move the file and it does not write a journal row. Health was still connection refused after the copy. The DSM task was not started. Starting it begins the startup walk from the beginning. Reorganize was not started.

## 2026-11-19 — Organize asks before it moves a photo

- Status: done
- Scope: Server Folder view, Date panel. Helper source gained `POST /v1/assets/{uid}/confirm`. The binary on the NAS was not replaced.
- Notes: Organize opens a dialog. Continue reads this page and the pages after it, and stops when a page neither moves a photo nor raises confidence. Yes reads this page. No leaves every file where it is. A photo with no date goes to Photos/_Review. A dated photo goes to Photos/YYYY/YYYY-MM-DD. A photo already in that year and day folder stays, including a file in a folder inside that day. When DateTimeOriginal, DateTimeDigitized, or DateTime matches that folder and catalog confidence is 0.00, confidence becomes 1.00. The catalog date still chooses the folder. It does not raise confidence by itself. A photo that moves and matches another file of the same size leaves a preview in Photos/_Duplicates. A photo that stays does not. The ZImager scheme compiled. The two new helper tests passed against a temporary catalog. The Mac tests were not run. Quit ZImager and rerun the scheme. The helper that is running now does not store that confidence. Replacing its binary is a separate step, and this session did not replace it. Reorganize was not started.

## 2026-11-19 — Clean deletes empty folders

- Status: done
- Scope: Server Folder view, Date panel. The helper is unchanged.
- Notes: Clean sits under Organize. Yes deletes the open folder and the folders inside it when they contain no files. No leaves them. A file, including a hidden file, keeps its folder. Photos itself stays. A symbolic link is left in place and is not followed. `rmdir` deletes a directory only when it is empty. The folder tree rereads the parent. Quit ZImager and rerun the scheme.

## 2026-11-19 — Organize the first page of a folder

- Status: done
- Scope: Server Folder view, Date panel. The helper is unchanged. Reorganize is not started.
- Notes: Organize moves the first page of the open folder. A still with no catalog date, DateTimeOriginal, DateTimeDigitized, or DateTime goes to Photos/_Review. A valid day goes to Photos/YYYY/YYYY-MM-DD. The preview JPEG is sent again after the folder is reread, when the new catalog row can be found. A same-size neighbor, or a file that had to be renamed, leaves that preview in Photos/_Duplicates. The bar is Organize, with the current step and the count against the photos in the folder. The folder is then reread. Quit ZImager and rerun the scheme.

## 2026-11-19 — Folder path shows the image count

- Status: done
- Scope: Server Folder view, the path to the right of Rescan.
- Notes: The path ends with the number of stills in that folder, as `(12345)`, once the folder has been counted. Videos are left out of the number. A long path still keeps the count visible. Quit ZImager and rerun the scheme.

## 2026-11-19 — Folder previews stay off the main thread

- Status: done
- Scope: Disk folder grid and Server folder grid. The helper is unchanged.
- Notes: A folder that still needs previews was reduced one file at a time. On Server that reduction ran on the main thread, so the pointer spun and Activity Monitor stayed near one core. Disk and Server now reduce four photographs at a time, and the ImageIO work runs off the main thread. The page on screen still comes before the rest of the folder. The one-file calls the tests use still reduce a single photograph. The ZImager scheme compiled. Disk previews remain small JPEGs in the temporary folder-preview cache. The default cap is 200 MB, and the oldest files are removed past that cap. Server catalog previews stay on the NAS. Quit ZImager and rerun the scheme.

## 2026-11-17 — ZImager 1.8.3

- Status: done
- Scope: ZImager 1.8.3. Merge two photos, Rename in Folder view, and Move to Folder on Disk. The Events and Reorganize buttons are hidden. Geometry keystone is unchanged. The helper is unchanged.
- Notes: Marketing version 1.8.3 is on the ZImager target. The test target stays 1.0. `CURRENT_PROJECT_VERSION` stays 1. Folder view on Disk and on Server joins exactly two stills from the same folder. The panel is "Merge two photos", under Move selected files. The first photo clicked is the left or the top. The second is the right or the bottom. Preview starts flush. Arrow keys move the second photo one pixel. Shift-arrow is also one pixel. Click zooms in. Option-click zooms out and stops at fit. Space-drag moves the whole picture and keeps the placement. Fit and 100% are on the preview. 100% is one point per pixel, centered on the seam, and a second click recenters. Merge writes an 8-bit TIFF in that folder named `{first}-{second}.tiff`. A taken name becomes `{name}-2.tiff` through `-999`. The originals stay. After the merge is accepted, right-click Rename changes the clicked file's name in the same folder. A taken name is refused. Disk Folder view has the same Move panel as Server, between Date and Merge. Unchecked creates the named folder under the opened tree root. Checked creates it inside the folder on screen. A file already there stays. Same names become name-2. The names _Removed, _Duplicates, and _Review are refused. The folder list reloads and the left tree shows the new folder. That move does not call the helper. The Events and Reorganize buttons are hidden. Reorganize, Review, and Duplicates still do not work and can lose photos. Leave them alone. Vertical keystone still changes the top and bottom edges. Horizontal keystone still changes the left and right edges. The disk image is `Releases/ZImager-1.8.3-macOS.dmg`, sha256 `cf273e50b5f2fc932cdcc91a332517a8484f1326831fb424ac32f9c2fb4bc8bb`, and it does not include the helper. Release builds arm64 only. The deployment target stays macOS 26.0.

## 2026-11-17 — ZImager 1.8.2

- Status: done
- Scope: ZImager 1.8.2. Move to Folder, Delete ALL on Photos/_Removed, folder-tree refresh, and previews for the rest of the open folder. The helper is unchanged.
- Notes: Marketing version 1.8.2 is on the ZImager target. The test target stays 1.0. `CURRENT_PROJECT_VERSION` stays 1. Server Folder view, under Date, has "Move selected files to specified Folder", a folder field, the checkbox "Sub-folder of this folder" (unchecked), and Move to Folder. Unchecked creates the named folder under Photos. Checked creates it inside the folder on screen. A file already in the destination stays put. Same names become name-2. The names _Removed, _Duplicates, and _Review are refused. After the move the folder on screen is read from the start, and a new folder shows in the left tree. Photos/_Removed replaces Find with Delete ALL. Yes deletes every file under that folder, including subfolders, leaves the folder, and clears the grid. Photos/_RemovedExtra is left alone. After the page on screen has previews, the rest of that folder keeps filling in. The slider line says "Making previews for the rest of this folder." The disk image is `Releases/ZImager-1.8.2-macOS.dmg`, sha256 `ae66c141fa072ea29492e964a7b6700a5b6c46153edb19826086007407f5b5bb`, and it does not include the helper. Reorganize, Review, and Duplicates still do not work and can lose photos. Leave them alone. Release builds arm64 only. The deployment target stays macOS 26.0.

## 2026-11-16 — Folder pages and a name filter

- Status: done
- Scope: Folder view in Disk and Server. The helper source accepts a name query. The binary on the NAS was not replaced. Marketing version stays 1.8.1. No disk image.
- Notes: A name field sits to the right of the folder path, with Find and Clear filter. Find or Return applies it. The match is a case-insensitive part of the file name. Find reads the whole folder, not only the first 200. Clear shows the folder again. An empty match says "No photos match that name." When a folder has more than 200 photos, a panel above Date shows the count, the slice, and First, Prev 200, Next 200, and Last. Two hundred or fewer leaves the column as it was. Videos stay on the first page and are not in the count. Server shows the first 200 while the title says "Counting photos…". A name search larger than 200 uses the same panel. Previews on later pages fill in after the page changes. The page on screen is reduced before the rest of the folder. Going back keeps previews already made. Find still works if the NAS helper is the older binary, because the Mac reads every page and keeps file names that match. There is still no disk image. The last disk image is `Releases/ZImager-1.8.0-macOS.dmg`. Reorganize, Review, and Duplicates still do not work and can lose photos. Leave them alone.

## 2026-11-16 — ZImager 1.8.1

- Status: done
- Scope: ZImager 1.8.1. Red-eye correction on the Touchup panel. The helper is unchanged. No disk image.
- Notes: Marketing version 1.8.1 is on the ZImager target. The test target stays 1.0. `CURRENT_PROJECT_VERSION` stays 1. Red Eye sits to the right of Scratches. Click the red of each pupil. Each click is a history step titled Red eye. The black center is about 20% larger than the red that was found, and that ring is filled with the pupil's dark color. A catchlight stays. A click on skin or lips does nothing. The repair uses model id `touchup-redeye-v1` and does not need LaMa. There is no disk image yet. The last disk image is `Releases/ZImager-1.8.0-macOS.dmg`. Reorganize, Review, and Duplicates still do not work and can lose photos. Leave them alone.

## 2026-11-14 — ZImager 1.8.0

- Status: done
- Scope: ZImager 1.8.0. Spot and Scratch speed, Flatten, export from the flattened TIFF, Revert, and Rescan.
- Notes: Marketing version 1.8.0 is on the ZImager target. The test target stays 1.0. `CURRENT_PROJECT_VERSION` stays 1. Each Spot or Scratch repair stores a small before picture and a small after picture. Undo pastes the before picture. Redo pastes the after picture. The next repair starts from the picture on screen. A click is a spot. A drag is a scratch. Flatten of a photograph with 112 spot and scratch removals finished in under a minute. Export of that flattened photograph reads the `.zflat` TIFF and finishes almost at once. Revert on the Flatten dialog restores the original when a flattened TIFF is present. Rescan sits beside Display Folder, walks that folder and its subfolders, drops catalog rows for files that are gone, and cleans the folder. The Clean folder menu item is removed. The disk image is `Releases/ZImager-1.8.0-macOS.dmg`, sha256 `410f5679f4a499246cb62b5135e1454ff694e7c197b7d49ff2c37284b3fdaf1a`, and it does not include the helper. Stop the DSM task before replacing the helper so Server Rescan uses the new binary. Do not open `catalog.db` from the Mac. Reorganize, Review, and Duplicates still do not work and can lose photos. Leave them alone. Release builds arm64 only. The deployment target stays macOS 26.0.

## 2026-11-13 — Remove object stays off the Disk toolbar

- Status: done
- Scope: Image toolbar. The helper is unchanged.
- Notes: The Remove object button is hidden in Disk, as it already was in Server. Quit ZImager and rerun the scheme.

## 2026-11-13 — PDF page buttons sit with the title

- Status: done
- Scope: PDF page picker. The helper is unchanged.
- Notes: Cancel and Open page sit beside Choose a page. A double-click on a thumbnail selects that page and opens it. Quit ZImager and rerun the scheme.

## 2026-11-13 — ZImager 1.7.5 detail sliders and frame offset

- Status: done
- Scope: Tone and Geometry panels. The helper is unchanged.
- Notes: Marketing version 1.7.5 is on the ZImager target. The test target stays 1.0. `CURRENT_PROJECT_VERSION` stays 1. Tone ends with a hairline, then Texture, Clarity, Details, and Sharpness. Details is a new tone amount at radius coefficient 8. Sharpness still lives on the geometry record. X offset and Y offset sit under Horizontal and slide the adjusted photograph inside its frame. Positive X moves it right. Positive Y moves it up. Older edit files decode the new fields as 0. Auto still leaves those sliders alone, and it still lifts a dark photograph. These panel changes ship in ZImager 1.8.0.

## 2026-11-10 — Auto lifts a dark photograph

- Status: done
- Scope: Tone Auto. The helper is unchanged.
- Notes: Auto still aims the middle of the picture at a mid gray. Contrast is left alone when raising it would darken that middle, because the contrast control pivots around linear 0.5, a bright gray. Exposure can rise by as much as 3 stops, and the 85th percentile keeps that rise from pushing the bright part through white. Blacks are not pulled down while the middle is below the target. Press Auto again to see the lighter picture. Quit ZImager and rerun the scheme.

## 2026-11-10 — ZImager 1.7.2

- Status: done
- Scope: ZImager 1.7.2. Video playback and graded export. Horizon, scratch fill, and the Spot size slider. The helper is unchanged.
- Notes: Marketing version 1.7.2 is on the ZImager target. The test target stays 1.0. `CURRENT_PROJECT_VERSION` stays 1. A double-click plays a video in the image view. Tone grades the frames, and Export writes a new MPEG-4. The original video is not changed. Horizon uses the pixels on screen. A scratch stroke fills from both sides. The Size slider stops at 200 preview pixels. Release builds arm64 only. The deployment target stays macOS 26.0. The keychain group and edit bookmarks are unchanged. Reorganize, Review, and Duplicates still do not work and can lose photos. Leave them alone. The disk image is `Releases/ZImager-1.7.2-macOS.dmg` and it does not include the helper. Stop the DSM task before replacing the helper. Do not open `catalog.db` from the Mac.

## 2026-11-10 — Export writes a graded movie

- Status: done
- Scope: ZImager Export. The helper is unchanged.
- Notes: Export on an open video writes a new MPEG-4 movie with the Tone adjustments on screen. The original video is not changed. A line on the picture shows how far the export has gotten. Geometry, Spot, Scratch, and the eyedropper stay off. The helper was not changed.

## 2026-11-10 — A video plays in the image view

- Status: done
- Scope: ZImager image view. The helper is unchanged.
- Notes: A double-click on a video in Disk folder view or the Server Photos grid plays it on the Image tab. The system play, pause, and scrub bar sit on the picture. Tone, the spectrum, Temperature, Tint, and Auto grade the frames while they play. That grade stays in memory for the session and is not written into the movie, a `.zimg`, or the folder JPEG. Opening the same video again in this session restores that grade. Geometry, Spot, Scratch, and the eyedropper stay off. The right-click menu still has Open with QuickTime Player, and Play opens the in-app player. The helper was not changed.

## 2026-11-10 — Horizon uses the pixels on screen

- Status: done
- Scope: ZImager Geometry. Horizon. The helper is unchanged.
- Notes: Two clicks were measured in a unit square. On a wide photo the vertical run was too large, so the straighten went past level. The clicks are still normalized, then scaled by the width and height of the picture on screen before `atan2`. The measured tilt is still written back, and the filter sign is unchanged. The helper was not changed.

## 2026-11-10 — Spot and Scratch size stops at 200

- Status: done
- Scope: ZImager Touchup size slider. The helper is unchanged.
- Notes: The Size slider ran from 8 to 400 preview pixels, so the smaller diameters were packed into the left half of the track. The maximum is now 200. The default stays 48, and a double-click still restores 48. The helper was not changed.

## 2026-11-10 — Release archive builds arm64

- Status: done
- Scope: ZImager archive. The helper is unchanged.
- Notes: Archive was compiling x86_64 as well as arm64. The macOS 27 SDK marks `Float16` unavailable for x86_64, so Geometry and Tone failed, and the vendored libjxl binaries are arm64 only. Debug already builds the active architecture, which is arm64 on this Mac. Release now sets `ARCHS` to arm64 and excludes x86_64. The helper was not changed.

## 2026-11-10 — Second spot click stays live

- Status: done
- Scope: ZImager Touchup. Manual Spot. The helper is unchanged.
- Notes: The second Spot click was asking Core Image for the size of the photograph the first repair was already rendering, so the pointer waited for that render. A click now uses the size measured when the picture was drawn. The next repair starts on the following turn of the run loop. When the saved picture does not already include earlier repairs, those repairs are applied on the repair queue. The helper was not changed.

## 2026-11-10 — Scratch fill follows both sides

- Status: done
- Scope: ZImager Touchup. Scratch stroke. The helper is unchanged.
- Notes: A scratch stroke was blending the two edge pixels straight across the brush and stamping one grain sample down that column. That painted lines across the repair. Each pixel now continues the picture from outside both sides of the stroke, mirrored across the edge, and mixes those by how far it sits from each side. A round end, where the other side is a long walk down the stroke, copies only the near side. Disks along the stroke are spaced at about a quarter of the radius. The helper was not changed.

## 2026-11-10 — Spot clicks stay live

- Status: done
- Scope: ZImager Touchup. Manual Spot. The helper is unchanged.
- Notes: A spot click was freezing the pointer because the working-image render and the on-screen picture were built on the main thread. Both now run on a serial queue, and the click returns as soon as the repair is added to the list. Further clicks join that list while one is running. A Spot repair reads a window around the circle, including the 30-pixel donor search and the small blurs, and copies that window back. Dust, Scratches, and Scratch strokes still read the whole frame, on that same queue. The helper was not changed.

## 2026-11-10 — ZImager 1.7.1

- Status: done
- Scope: ZImager 1.7.1. Spot click list. The helper is unchanged.
- Notes: Marketing version 1.7.1 is on the ZImager target. The test target stays 1.0. `CURRENT_PROJECT_VERSION` stays 1. Spot clicks, scratch strokes, and the Dust and Scratches buttons share one list of 64 repairs. A click during a repair waits in that list. The repairs run one at a time, each on the picture the previous repair produced, and each is its own history step. The canvas banner and the Touchup panel say how many spots are left, including the one running. A click past 64 is not added. Undo, redo, reset, and opening another photograph drop the list. The deployment target stays macOS 26.0. The keychain group and edit bookmarks are unchanged. Reorganize, Review, and Duplicates still do not work and can lose photos. Leave them alone. The disk image is `Releases/ZImager-1.7.1-macOS.dmg` and it does not include the helper. Stop the DSM task before replacing the helper. Do not open `catalog.db` from the Mac.

## 2026-11-10 — Spot click list

- Status: done
- Scope: ZImager Touchup. Manual Spot.
- Notes: Spot clicks, scratch strokes, and the Dust and Scratches buttons share one list of 64 repairs. A click during a repair waits in that list. The repairs run one at a time, each on the picture the previous repair produced, and each is its own history step. The canvas banner and the Touchup panel say how many spots are left, including the one running. A click past 64 is not added. Undo, redo, reset, and opening another photograph drop the list. The helper was not changed.

## 2026-11-09 — ZImager 1.7.0

- Status: done
- Scope: ZImager 1.7.0. The ZImage editor and ZImage Library are removed from the project. The helper is unchanged.
- Notes: The only Mac app target is ZImager, bundle id `com.Win32Forth.ZImager`, scheme `ZImager`. The old targets, schemes, Info plists, entitlements, and source folders `ZImage/` and `ZImageLibrary/` are gone. `ZImageTests` hosts on `ZImager.app` and imports `ZImager`. A still opens in this app. The deployment target is macOS 26.0. The vendored libjxl and libwebp binaries declare that same minimum. The keychain group stays `X5YCJL3LJ8.com.Win32Forth.ZImage`. Saved edit bookmarks stay in `com.Win32Forth.ZImage.editBookmarks`. The preference import still reads the old ZImage Library container for the helper host and the library folder. The Xcode project file remains `ZImage.xcodeproj`. Reorganize, Review, and Duplicates still do not work and can lose photos. Leave them alone. The disk image is `Releases/ZImager-1.7.0-macOS.dmg` and it does not include the helper. Stop the DSM task before replacing the helper. Do not open `catalog.db` from the Mac.

## 2026-11-09 — ZImage and ZImage Library leave the project

- Status: done
- Scope: ZImager is the only Mac app target. ZImageTests hosts on it.
- Notes: The ZImage and ZImage Library targets, schemes, Info plists, entitlements, and source folders are removed. The scheme to run is `ZImager`. Tests import `ZImager` and the test host is `ZImager.app`. The sidebar items are Photos, Review, and Duplicates. A still opens with bundle id `com.Win32Forth.ZImager`. The keychain group stays `X5YCJL3LJ8.com.Win32Forth.ZImage`. Saved edit bookmarks stay in the suite `com.Win32Forth.ZImage.editBookmarks`. The preference import still reads the old ZImage Library container. Reorganize, Review, and Duplicates still do not work and can lose photos. Leave them alone.

## 2026-11-09 — ZImager 1.6.0

- Status: done
- Scope: ZImager 1.6.0. ZImage and ZImage Library stay at 1.0. The helper gained place-date moves and folder cleanup.
- Notes: View → Folder View is ⌘F and View → Edit View is ⌘E, in Disk and Server. In Edit view the left and right arrows step between photos. Switching Disk and Server keeps the folder scroll position. A newly chosen folder opens at the top. Control-click selects photos that are not next to each other. Folder view has Export and Print beside Paste settings. Edit view prints the open photo. File → Print is ⌘P. Videos are skipped. Copy settings and Paste settings are on the Edit menu as ⌘⇧C and ⌘⇧V, and on the right-click menu. They copy Tone and Geometry. Tone has Auto and Reset. Auto sets Exposure, Contrast, Highlights, Shadows, Whites, and Blacks in one step. Reset returns the photo to the start and leaves the later steps for redo. Spectrum sits above Tone, with low, middle, and high handles. Double-click a handle to reset it. The panel folds like the others. Server right-click says Edit Image. Remove Object is not in the View menu, and the Server image toolbar does not show it. Remove from library moves the selected Server files into `Photos/_Removed`. They are not deleted. Progress is shown and the folder list keeps its place. Set date writes the typed date on every selected photo and video and moves each file into its date folder. `POST /v1/assets/{uid}/place` does that move. `POST /v1/assets/{uid}/date` still stores the date and leaves the file where it is. A folder named Updated under `Photos/_Review` is a staging shelf, not an event name. Clean folder is in the Server three-bar menu. `POST /v1/folders/clean` drops catalog rows in that folder whose files are gone when another file there has the same name and size. It does not delete a file. A missing photo with no match stays. Reorganize, Review, and Duplicates still do not work and can lose photos. Leave them alone. Stop the DSM task before replacing the helper. Do not open `catalog.db` from the Mac.

## 2026-11-09 — ZImager 1.5.0

- Status: done
- Scope: ZImager 1.5.0. ZImage and ZImage Library stay at 1.0.
- Notes: ZImager is the app to run. Disk is the editor and Server is the library, in one window. Source Disk/Server sits on the top bar. Disk shows Open File and Open Folder. Server shows Choose Library Base Folder and Pair with Helper. Folder and Image sit in the center. Rotate left and Rotate right sit beside those tabs in both views. Paste settings sits only in Folder view, and it stays off until Copy settings has been used. Shift-click selects a range of stills. Rotate and paste save each selected photo and rebuild those previews. Videos are skipped. An edit on the open photo rebuilds that photo's folder preview. Server Photos lists stills and videos together. The Videos sidebar entry is gone. A video opens in QuickTime Player. Server Image mode shows Undo, Redo, Copy settings, and Paste settings. The date panel is on the right of a Server folder. Events and Reorganize replace that panel while they are on. The helper status line sits to the right of Server and refreshes about every 10 seconds. The helper source prefers the folder on screen, writes 256 px previews, and reports the cache check, the file listing, and the catalog match while it walks. Reorganize, Review, and Duplicates do not work yet. Using them can lose photos. Leave them alone. Do not press Start, Pause, Continue, Find duplicates, or Delete all duplicates. Server mode needs the helper. `README.md` says how to build the ARM64 binary, copy it to `PhotoVideoAudio/.zimage/bin/zimage-helper`, and start it from DSM Task Scheduler with `GOMEMLIMIT=160MiB`. The disk image does not include the helper. Stop the task before replacing the binary. Do not open `catalog.db` from the Mac.

## 2026-11-07 — Folder previews appear as they are built

- Status: done
- Scope: ZImage editor Folder view.
- Notes: Choosing a folder still lists every file at once. Each preview JPEG is shown in its cell as soon as that file is written. The grid no longer waits until the whole folder is done. The helper was not changed.

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
