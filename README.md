# ZImage

ZImager 1.9.1 is the app. It is one window. Disk is the editor. Server is the library. The separate ZImage editor and ZImage Library are no longer in this project.

`DESIGN.md` is the plan. `STATUS.md` is the iteration log, newest first.

## Do not use yet

Reorganize, Review, and Duplicates do not work yet. Using them can lose photos. The Events and Reorganize buttons are hidden until those tools are ready. Leave Reorganize, Review, and Duplicates alone. Do not press Start, Pause, Continue, Find duplicates, or Delete all duplicates.

Disk, and Server browsing of a folder, are the parts to use. Rotate, paste, export, print, and the image adjustments save the photo and rebuild its preview.

## What 1.9.1 changes

The app and the helper it installs are 1.9.1. A saved change on the main server is listed in the mirror catalog at that moment. A library scan already running pauses for that listing, then continues. Health reports `helperVersion`. ZImager writes `role: "mirror"` only when the share's VERSION file is 1.9.1. `.zimg` appVersion stays 1.0.0. The disk image is `Releases/ZImager-1.9.1-macOS.dmg`. Delete ALL on Photos/_Removed deletes every file in that folder on the server on screen, including the mirror. The other server's Photos/_Removed stays. Photos/_RemovedExtra is left alone.

## What 1.9.0 changes

The Server menu can keep more than one server. Add Server copies the helper onto a mounted share. Update Helper and Uninstall Helper run after TCP port 8742 on that server refuses a connection. Uninstall removes the helper programs and VERSION. It leaves the catalog, the photos, the config, and the token. Forget Server removes that server from this Mac and removes its keychain item. The photos stay on the server.

Mirror Setup names one main server and one mirror. Mirroring copies each file that is missing on the mirror, or whose size differs, into the same folder and file name. It also copies the edit file and the flattened TIFF beside that photo: `.zimg`, `.ztiff`, `.zflat`, and `.zjpg`. It copies one file at a time. A file it copies is listed on the mirror. That listing does not walk the rest of Photos. The listing is written before the helper answers. A library scan already running pauses for that listing, then continues. A file that exists only on the mirror stays there and shows a red border. Recover photo copies it onto the main server under the same name. A name that is already in that folder gains `-2`, then `-3`. Discard photo moves it to `Photos/_Removed` on the mirror. Remove from Library on the main server also moves the matching mirror file into `Photos/_Removed`. A recovered beside-name moves the mirror original. Unlink leaves both libraries in place so the mirror can become the main server.

On the mirror, date changes, move, merge, rename, save, and paste stay off. Build previews stays. Export and print stay.

A rename on the main server is written onto the mirror. The mirror keeps that work in `.zimage/mirror-ops.json` and finishes one item at a time, in the order the renames happened. A folder rename moves the folder. A file rename moves the file and the edit files beside it. The next item waits until the mirror reaches it.

Mirror Image view hides the editing panels. Spectrum stays, with its handles locked. History stays. Select, Crop, Undo, and Redo stay off. Edit in Library, under Spectrum, opens that photo on the main server. An orphan shows Recover and Edit photo, which copies it onto the main server under the same name and opens that copy. A name that is already in that folder gains `-2`. The name beside Disk/Server and the menu checkmark move to that server. A saved change on the main server is copied to the mirror then. The mirror catalog is updated at that moment, including while the mirror is scanning its library. Crop, Rotate, Flip, and Paste settings copy that photo's edit files. Flatten copies the flattened TIFF and an empty edit list, and switching to the mirror waits until that picture is there. Duplicate copies the new TIFF and the preview JPEG the folder grid uses. Merge copies the new photograph. Command-S and leaving Image view do the same.

On the mirror folder grid, a selected orphan has a purple border and any other selected photo has a green border. Recover photo and Discard photo are available when the page on screen has an orphan. Discard all Orphans moves every orphan on that page to `Photos/_Removed`. The Date panel and its preview stay on the mirror. The buttons that set or change a date stay off.

Mirroring remembers its place in `.zimage/mirror-progress.json` on the mirror. Quit and start again, and it continues from that place. The mount check, the saved place, the rename list, the folder reading, and the copying stay off the main thread, so the window can still be used. Unlink clears the saved place.

The helper source is 1.9.1. Health reports `helperVersion`. A server whose config says `role: "mirror"` refuses edits after that helper is restarted. Discard, folder rescan, and pairing stay available. ZImager writes that role only when the share's VERSION file is 1.9.1. `POST /v1/reorg/discard` drops a Reorganize plan that has not started copying, and leaves the photo files where they are. The disk image is `Releases/ZImager-1.9.1-macOS.dmg`. 1.8.6 behavior below is still in this app.

## What 1.8.6 changes

View has Flip Left/Right and Flip Top/Bottom. Flip Left/Right is above Flip Top/Bottom. Both sit under Rotate Counterclockwise and above Eyedropper. Flip Left/Right mirrors the left and right edges of the picture on screen. Flip Top/Bottom mirrors the top and bottom. Choosing the same command again puts that edge back. A later rotate keeps the mirror with the photograph. A crop and a repair follow the photograph. An older edit file that has no flip stays upright.

Leaving Image adjustment for Folder view returns to Zoom. A tool that stays clicked, including Color, Spot, Geometry, Horizon, the eyedropper, and Select, is released.

Flatten is available whenever a still photograph is open, including a photograph with no edits. It stays off while a video is open, while the PDF page picker is open, and while Flatten or Export is already writing.

Flatten again asks first. The question is "Flatten this photograph again?" Continue replaces the library TIFF with the spots and other edits made since the last flatten. The edit list returns to the start. The original photograph stays unchanged. Revert can only return to that original with no edits. The TIFF that was replaced is not kept as a separate step. Duplicate still writes a TIFF next to the photograph and leaves these edits in place. A photograph that has no library record offers Duplicate and Cancel.

Open page in a PDF opens the page whose thumbnail you clicked. A double-click opens that same page.

Rescan in Server Folder view checks the photos on the page on screen, up to 2,000, and stops there. A file on that page that is gone drops its catalog row. A file that is not on the page stays in the catalog. A new file that is not already listed is not added. Move, Organize, and Delete ALL still read the folders they changed. If this helper cannot rescan one page, the folder is not walked.

Automatic previews for a folder stop at the page on screen. Build previews still covers the open folder.

The helper source adds a rescan of one page. The binary on the NAS already has that route. This disk image does not include the helper. Stop the DSM task before you replace the binary. 1.8.5 behavior below is still in this app.

## What 1.8.5 changes

Dragging the photograph moves it. The scroll wheel zooms in and out around the pointer. Scroll up zooms in. A trackpad pinch still zooms.

Curve sits between Tone and Color. The graph shows the photograph's brightness. RGB shapes the whole picture. Red, Green, and Blue shape one channel after that. Linear, Matte, Film Moody, Punch, and Lo-fi set the RGB curve. Drag a handle. Click the curve to add a point, up to eight. Double-click a middle handle to remove it. Double-click an end to put that corner back.

Vignette sits under Touchup. Amount, Midpoint, Roundness, Feather, X, and Y shape the edges. Negative Amount darkens them. Positive Amount lightens them. Positive X moves the clear center right. Positive Y moves it up.

Flatten asks before it writes. Duplicate, on that dialog, writes a flattened TIFF next to the photograph. The name gains `-2`, then `-3` when that name is taken. The photograph and its edits stay as they are.

Folder view folds each panel on the right from an arrow at the end of its title. Preview is the word above the picture. Build previews sits under Merge two photos, on Disk and on Server Photos. It builds a preview for each photo in the open folder that does not already have one. Videos are skipped. Clear the name filter first. Disk keeps those previews in its temporary cache. Server stores them through the helper.

Sigma X3F files appear in the folder grid. Opening one develops the sensor image on this Mac and edits that picture. Export can write it as a TIFF or a DNG. The color is the bundled converter's sRGB, not Sigma Photo Pro. If that development cannot run, ZImager opens the embedded preview and says so. The helper stores that embedded preview and does not develop the sensor. X3I files are not opened.

Right-click Rename of a file under Photos keeps the same catalog id. Photos/_Removed, Photos/_Duplicates, and Photos/_Review keep their names. The helper on the NAS already has that route and the X3F preview. This disk image does not include the helper. Stop the DSM task before you replace the binary. 1.8.4 behavior below is still in this app.

## What 1.8.4 changes

Folder view stays responsive while previews are built. Disk and Server prepare four photographs at a time, and that work stays off the main thread. The page on screen still comes first. Disk previews remain temporary JPEGs on this Mac, capped at 200 MB, and the oldest files are removed past that cap. Server previews stay on the NAS.

In Server Folder view, the path to the right of Rescan ends with the number of stills in that folder, as `(12345)`, once the count is finished. Videos are left out of the number.

The Date panel in Server Folder view has Organize and Clean. Organize opens a dialog. Continue reads this page and the pages after it, and stops when a page neither moves a photo nor raises confidence. Yes reads this page. No leaves every file where it is. A photo with no date goes to `Photos/_Review`. A dated photo goes to `Photos/YYYY/YYYY-MM-DD`. A photo already in that year and day folder stays. When DateTimeOriginal, DateTimeDigitized, or DateTime matches that folder and catalog confidence is 0.00, confidence becomes 1.00. A photo that moves and matches another file of the same size leaves a preview in `Photos/_Duplicates`.

Clean asks before it deletes anything. Yes deletes Thumbs.db, ehthumbs.db, desktop.ini, .DS_Store, and AppleDouble `._` files in that folder and its subfolders, then deletes a folder that has nothing else in it. No leaves them. A photo or any other file keeps its folder. Photos itself stays. A symbolic link is left in place.

Right-click a folder in the Disk tree or the Server tree and choose Rename. The folder stays in its parent. Spaces inside the name stay. Photos, Photos/_Removed, Photos/_Duplicates, and Photos/_Review keep their names. A symbolic link is left in place. A Disk folder outside the library is renamed on this Mac. A folder under Photos is renamed on disk, then the catalog follows that name and keeps each file's id, including a folder that holds only videos. Edits and previews stay with that id. The app waits up to three minutes for the catalog write. If the helper cannot be reached, the folder is put back.

Rotate left or Rotate right keeps Vertical on the top and bottom edges of the picture on screen, and Horizontal on the left and right. A crop made before that turn stays on the same part of the photograph. A Spot, Scratch, or Red Eye repair made before that turn stays on the pixels it repaired.

The helper source adds folder rename and the confidence update Organize uses. The disk image does not include the helper. The copy running on the NAS already has those two routes. This source also accepts a rename the catalog has already recorded. Stop the DSM task before you replace the binary. 1.8.3 behavior below is still in this app.

## What 1.8.3 changes

Folder view, on Disk and on Server, can join two still photos into one TIFF. Select exactly two photos in the same folder. The panel is "Merge two photos", under Move selected files. Choose Horizontal or Vertical. The first photo you click is the left side, or the top. The second is the right side, or the bottom. A sideways pair stays sideways. Preview starts the two photos flush, edge to edge, so you line up the seam yourself.

Preview opens over the folder. Arrow keys move the second photo one pixel at a time: left, right, up, and down. Shift-arrow is also one pixel. Click zooms in at the pointer. Option-click zooms out, and it stops when the whole join fits. Hold Space and drag to move the whole picture. The two photos keep the placement you set. Fit shows the whole join. 100% shows one image pixel per point, centered on the seam, and clicking 100% again recenters. Changing Horizontal or Vertical returns to a flush join. Cancel closes the preview and writes nothing.

Merge writes an 8-bit TIFF in the same folder and leaves the two originals. The name is the first file's name, a hyphen, and the second file's name, with `.tiff`. If that name is taken, the file is `{name}-2.tiff`, then `-3`, up through `-999`. An overlap is blended. A gap along the join stays black. A slide past the edge fills the clear band from the nearest pixels of the photo.

After the merge is accepted, right-click a file in Folder view and choose Rename. Rename is hidden while the preview is up. The file stays in that folder. A name that is already there is refused. An empty name, ".", "..", a slash, a colon, or a name the file system will not take is refused. A change of capitalization only is allowed.

Disk Folder view has the same Move panel as Server. It sits between Date and Merge. The title is "Move selected files to specified Folder". The checkbox "Sub-folder of this folder" starts unchecked. Unchecked, the named folder is created under the folder you opened, the root of the tree. Checked, it is created inside the folder on screen. A file already in the destination stays where it is. Two files with the same name become name-2. The names _Removed, _Duplicates, and _Review are refused. The folder list reloads, and a new folder shows in the left tree. This move does not use the helper.

The Events button and the Reorganize button are hidden. Those tools are not ready. Geometry keystone is unchanged. Vertical still changes the top and bottom edges. Horizontal still changes the left and right edges.

The helper is unchanged. This disk image does not include it. 1.8.2 behavior below is still in this app.

## What 1.8.2 changes

Server Folder view can move the selected files into a folder you name. The panel sits under Date. Its title is "Move selected files to specified Folder". Type a name and press Move to Folder. The checkbox "Sub-folder of this folder" starts unchecked. Unchecked, the folder is created under Photos. Typing Miracle while Blogger 1600 is open creates Photos/Miracle and moves the selected files there. Checked, the folder is created inside the folder on screen, so that same name becomes Photos/Blogger 1600/Miracle. A file already in the destination stays where it is. Two files with the same name become name-2. The names _Removed, _Duplicates, and _Review are refused. After the move, the folder on screen is read again, and a new folder shows in the left tree without quitting.

When the folder on screen is Photos/_Removed, the name field, Find, and Clear filter are replaced by Delete ALL. It asks "Are you sure, all _Removed photos will be deleted from the server?" Yes deletes every file in that folder, including files in subfolders, and leaves the folder. Photos/_RemovedExtra is left alone. The grid clears when the folder is empty.

While a folder is open, previews keep filling in for the rest of that folder after the page on screen is done. The slider line says "Making previews for the rest of this folder."

The helper is unchanged. This disk image does not include it. 1.8.1 behavior below is still in this app.

## What 1.8.1 changes

Red Eye sits to the right of Scratches on the Touchup panel, and on the menu beside Remove Scratches. Click Red Eye, then click the red of each pupil. Click Red Eye again to leave. Each eye is its own history step, titled Red eye. The black center is about 20% larger than the red the click found, so the red ring around the pupil is included. That ring is filled with the pupil's dark color. A white catchlight stays. A click on skin or lips does nothing.

Folder view, in Disk and in Server, has a name field to the right of the folder path, with Find and Clear filter. Typing does not filter until Find or Return. The match is a case-insensitive part of the file name. Find searches the whole folder, not only the first 200 photos. Clear shows the folder again. When nothing matches, the grid says "No photos match that name."

When a folder has more than 200 photos, a panel above Date shows the count, for example "1,842 photos", the slice on screen, for example "201–400 of 1,842", and First, Prev 200, Next 200, and Last. A folder of 200 photos or fewer leaves that column as it was. Videos stay on the first page and are not in the count. On Server, the first 200 appear while the title says "Counting photos…". A name search with more than 200 matches uses the same panel.

Previews on the second page and later fill in after you change pages. The page on screen is reduced before the rest of the folder. Going back keeps previews that were already made.

The helper source accepts a name on the asset list. The binary on the NAS was not replaced. Find does not need that replacement: it still reads every page and keeps file names that match. 1.8.0 behavior below is still in this app.

## What 1.8.0 changes

Spot and Scratch removal is much faster. Each repair keeps a small before picture and a small after picture of the pixels that changed. Undo pastes the before picture. Redo pastes the after picture. The rest of the photograph stays. The next spot starts from the picture already on screen, so moving from spot to spot is almost immediate.

Spot and Scratch are one tool. A click repairs a spot. A drag repairs a scratch. The automatic Dust and Scratches buttons are the same as before.

Flatten writes a full-size LZW TIFF beside the edit file, with the extension `.zflat`. A photograph with 112 spot and scratch removals flattened in under a minute. Export of that flattened photograph reads the TIFF, so it finishes almost at once. The original file stays as it is. Flatten keeps the JPEG sidecar and the `.zimg`. Flatten again overwrites the TIFF and clears the edit list. Duplicate, on that same dialog, writes the flattened TIFF next to the photograph. The name gains `-2`, then `-3` when that name is taken. The photograph and its edits stay as they are. Revert, on the Flatten dialog, restores the original when a flattened TIFF is already there.

Rescan sits beside Display Folder. It walks that folder and its subfolders, drops catalog rows for files that are gone, and cleans the folder. The Clean folder menu item is removed. A slow rescan shows a progress bar. Rescan is in the helper source. The disk image does not include the helper. Stop the DSM task before you replace that binary.

A DNG export writes each tile upright. The PDF page picker puts Cancel and Open page beside the title, and a double-click opens the page. The Remove object button is hidden in Disk and in Server.

Tone ends with Texture, Clarity, Details, and Sharpness. Geometry has X offset and Y offset under Horizontal. Auto lifts a dark photograph.

1.7.5, 1.7.2, 1.7.1, 1.7.0, and 1.6.0 behavior below is still in this app. This build is Apple Silicon and runs on macOS 26.

## What 1.7.5 changes

Tone ends with a thin line, then Texture, Clarity, Details, and Sharpness. Details is a new slider between Clarity and Sharpness. Sharpness moved there from Geometry. Its saved value is unchanged.

Geometry has X offset and Y offset just under Horizontal. They slide the adjusted photograph inside its frame. Positive X moves it right. Positive Y moves it up. The frame stays the same size.

Auto lifts a dark photograph. The Remove object button is hidden in Disk and in Server. The helper for those panels is unchanged. 1.7.2 behavior below is still in this app.

## What 1.7.2 changes

A double-click on a video in Disk folder view or the Server Photos grid plays it on the Image tab. The system play, pause, and scrub bar sit on the picture. Tone, the spectrum, Temperature, Tint, and Auto grade the frames while they play. Export writes a new MPEG-4 movie with those adjustments. The original video is not changed. Open with QuickTime Player stays on the right-click menu. Geometry, Spot, Scratch, and the eyedropper stay off while a video is open.

Horizon levels a wide or tall photo without tilting past the line you clicked. Scratch repair continues the picture from both sides of the stroke. The Spot and Scratch Size slider stops at 200 preview pixels. The default stays 48.

The helper is unchanged. 1.7.1 and 1.7.0 behavior below is still in this app. This build is Apple Silicon and runs on macOS 26.

## What 1.7.1 changes

Spot clicks stack. You can click the next speck while an earlier repair is still running. The list holds 64 repairs, shared by Spot clicks, Scratch strokes, and the Dust and Scratches buttons. Each repair is its own history step and uses the picture the previous repair produced. The banner on the photograph and the Touchup panel say how many spots are left, including the one running. A click past 64 is not added. Undo, redo, reset, and opening another photograph clear the list.

The helper is unchanged. 1.7.0 and 1.6.0 behavior below is still in this app.

## What 1.7.0 changes

ZImager is the only Mac app. The old ZImage target and the old ZImage Library target, their schemes, and their source folders are removed. Run the `ZImager` scheme. `ZImageTests` hosts on `ZImager.app`. The deployment target is macOS 26.0, so this build runs on a Mac that has macOS 26.

A still opens in ZImager, bundle id `com.Win32Forth.ZImager`. The helper token stays in the keychain group `X5YCJL3LJ8.com.Win32Forth.ZImage`. Saved edit bookmarks stay in the suite `com.Win32Forth.ZImage.editBookmarks`. The first Server launch can still read the old ZImage Library preference file for the helper host and the library folder.

The helper is unchanged. 1.6.0 behavior below is still in this app.

## What 1.6.0 adds

View → Folder View is ⌘F. View → Edit View is ⌘E. Both work in Disk and Server. In Edit view, the left and right arrow keys move to the previous and next photo. Switching between Disk and Server keeps the folder scroll position. Choosing another folder moves that list to the top. Control-click selects photos that are not next to each other.

Folder view has Export and Print beside Paste settings. Edit view prints the open photo. File → Print is ⌘P. Videos are skipped. Copy settings and Paste settings are on the Edit menu as ⌘⇧C and ⌘⇧V, and on the right-click menu. They copy Tone and Geometry.

Tone has Auto and Reset beside the title. Auto sets Exposure, Contrast, Highlights, Shadows, Whites, and Blacks in one step. Reset returns the photo to the start. Redo brings each change back, one at a time. Spectrum sits above Tone, with low, middle, and high handles. Double-click a handle to reset it. The panel folds like the others.

On Server, the right-click command is Edit Image. Remove Object is not in the View menu, and the Server image toolbar does not show it. Remove from library moves the selected Server files into `Photos/_Removed`. The files stay there for a later deletion. The folder list keeps its place while that runs, and a progress line is shown. Set date writes the typed date on every selected photo and video and moves each file into its date folder, with progress. A folder named Updated under `Photos/_Review` is a staging shelf, not an event name.

Clean folder is in the Server three-bar menu. It removes catalog records in the open Photos folder whose files are already gone, when another file in that folder has the same name and the same size. Photos on disk stay. A missing photo with no match is left in the catalog. Set date's file move and Clean folder need the helper from this version. Stop the DSM task before you replace that binary.

## Install ZImager

The published disk image is `Releases/ZImager-1.9.1-macOS.dmg`, sha256 `7dc9f83453eefeb837b17cd8d86de0570672954496376d4c707371d0d990cb99`, 26626667 bytes. It contains `ZImager.app` and `README.txt`. The image stays out of git. The text in the image is `Releases/ZImager-1.9.1-README.txt`. It is signed with Developer ID Application: Thomas Zimmer (X5YCJL3LJ8) and notarized by Apple.

1. Open the disk image.
2. Drag **ZImager.app** into Applications.
3. The first time you open ZImager, macOS asks you to confirm that you downloaded it from the internet. Click Open.

This copy is signed with a Developer ID and notarized by Apple. A Mac set to allow apps from the App Store only will still refuse it.

## Helper on a Synology

Skip this if you only use Disk.

Server mode needs `zimage-helper` running on the NAS. The disk image does not include it. The Mac never opens `catalog.db`. The 1.8.0 helper source adds Rescan. The 1.8.4 helper source adds folder rename and the confidence update Organize uses. The 1.8.5 helper source adds `POST /v1/files/rename` and an X3F embedded preview. The 1.8.6 helper source adds `POST /v1/folders/rescan-page`. The 1.9.0 helper source adds `helperVersion` on health, `role: "mirror"`, and `POST /v1/reorg/discard`. The 1.9.1 helper source pauses a folder scan so a page listing can be written first. It does not develop the Foveon sensor.

Each ZImager build runs `Vendor/embed-helper.sh` and puts Linux arm64 and amd64 binaries in the app. Add Server and Update Helper copy those onto the share, with a launcher named `zimage-helper`. The launcher picks the CPU, sets `GOMEMLIMIT=160MiB`, turns copy-on-write off for the catalog directory, and writes `config.yaml` only when that file is missing. The DSM task runs `sh` on that launcher. Checking Enabled does not start the task.

To stop the helper, click Enabled on `zimage-helper-stop`, uncheck Enabled on `zimage-helper`, select `zimage-helper-stop`, and click Run. To start it, uncheck Enabled on `zimage-helper-stop`, click Enabled on `zimage-helper`, select `zimage-helper`, and click Run. Update Helper and Uninstall Helper wait until port 8742 refuses a connection. The running program is `zimage-helper-aarch64`, or `zimage-helper-x86_64` on an Intel NAS.

Stop the DSM task before you replace the binary by hand. The steps below build that binary from this tree.

1. On a Mac, from `Helper/` in this repo:

```sh
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o zimage-helper ./cmd/zimage-helper
```

2. Copy `zimage-helper` to `PhotoVideoAudio/.zimage/bin/zimage-helper` on the share. Mode 0700. The binary stays on the data volume because a DSM update can clear `/usr/local`.

3. Copy `Helper/config.example.yaml` to `PhotoVideoAudio/.zimage/config.yaml`. Set `library_root_local` to the path DSM uses. On volume 1 that is often `/volume1/BackupData/PhotoVideoAudio`. Leave `scope_relative` as `Photos`.

4. Before the first `catalog.db` on btrfs, turn copy-on-write off. The helper does not do this:

```sh
mkdir -p /volume1/BackupData/PhotoVideoAudio/.zimage/catalog
chattr +C /volume1/BackupData/PhotoVideoAudio/.zimage/catalog
```

5. In DSM, open **Control Panel → Task Scheduler → Create → Triggered Task → User-defined script**. Event: **Boot-up**. Run it as a user who can read and write the shared folder. Do not run it as root. User-defined script:

```sh
export GOMEMLIMIT=160MiB
/volume1/BackupData/PhotoVideoAudio/.zimage/bin/zimage-helper -config /volume1/BackupData/PhotoVideoAudio/.zimage/config.yaml
```

6. Run the task. A second start exits while `.zimage/helper.lock` is held. The helper listens on IPv4 port 8742.

7. In ZImager, choose Server, then **Pair with Helper**. The first start writes `PAIRING-TOKEN` on the share. ZImager reads it over the mounted share and claims it.

A later DSM update can remove the task while the binary remains. Open Task Scheduler and confirm the boot task still runs that command.

The first walk of a large Photos tree takes a long time. The line to the right of Server names the task the helper is on. Open the folder you want. The helper makes that folder's previews before the rest of the library.

## Build

The Xcode command-line tools are the default on this machine. Point the build at Xcode:

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
cd /path/to/ZImage
xcodebuild -project ZImage.xcodeproj -scheme ZImager -destination 'platform=macOS,arch=arm64' build
```

The scheme is `ZImager`. `ZImageTests` is the test target and it hosts on that app. `Helper/zimage-helper` is a local build product and is not in this repo.
