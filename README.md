# ZImage

ZImager 1.8.4 is the app. It is one window. Disk is the editor. Server is the library. The separate ZImage editor and ZImage Library are no longer in this project.

`DESIGN.md` is the plan. `STATUS.md` is the iteration log, newest first.

## Do not use yet

Reorganize, Review, and Duplicates do not work yet. Using them can lose photos. The Events and Reorganize buttons are hidden until those tools are ready. Leave Reorganize, Review, and Duplicates alone. Do not press Start, Pause, Continue, Find duplicates, or Delete all duplicates.

Disk, and Server browsing of a folder, are the parts to use. Rotate, paste, export, print, and the image adjustments save the photo and rebuild its preview.

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

Flatten writes a full-size LZW TIFF beside the edit file, with the extension `.zflat`. A photograph with 112 spot and scratch removals flattened in under a minute. Export of that flattened photograph reads the TIFF, so it finishes almost at once. The original file stays as it is. Flatten keeps the JPEG sidecar and the `.zimg`. Flatten again overwrites the TIFF and clears the edit list. Revert, on the Flatten dialog, restores the original when a flattened TIFF is already there.

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

The disk image is `Releases/ZImager-1.8.4-macOS.dmg`. It contains `ZImager.app` and `README.txt`.

1. Open the disk image.
2. Drag **ZImager.app** into Applications.
3. Double-click **ZImager**. macOS says it could not verify that the app is free of malware. Close that dialog.
4. Open **System Settings → Privacy & Security**. Scroll to Security until ZImager is listed as blocked. Click **Open Anyway**.
5. Confirm **Open Anyway** again if asked, then enter your password.

After that, double-click ZImager and it will run. ZImager is built on this Mac with Apple's tools. It is not notarized for distribution. That approval is required once.

## Helper on a Synology

Skip this if you only use Disk.

Server mode needs `zimage-helper` running on the NAS. The disk image does not include it. The Mac never opens `catalog.db`. The 1.8.0 helper source adds Rescan. The 1.8.4 helper source adds folder rename and the confidence update Organize uses. Stop the DSM task before you replace the binary.

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
