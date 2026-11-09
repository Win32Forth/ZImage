# ZImage

ZImager 1.7.0 is the app. It is one window. Disk is the editor. Server is the library. The separate ZImage editor and ZImage Library are no longer in this project.

`DESIGN.md` is the plan. `STATUS.md` is the iteration log, newest first.

## Do not use yet

Reorganize, Review, and Duplicates do not work yet. Using them can lose photos. Leave those controls alone. Do not press Start, Pause, Continue, Find duplicates, or Delete all duplicates.

Disk, and Server browsing of a folder, are the parts to use. Rotate, paste, export, print, and the image adjustments save the photo and rebuild its preview.

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

The disk image is `Releases/ZImager-1.7.0-macOS.dmg`. It contains `ZImager.app` and `README.txt`.

1. Open the disk image.
2. Drag **ZImager.app** into Applications.
3. Double-click **ZImager**. macOS says it could not verify that the app is free of malware. Close that dialog.
4. Open **System Settings → Privacy & Security**. Scroll to Security until ZImager is listed as blocked. Click **Open Anyway**.
5. Confirm **Open Anyway** again if asked, then enter your password.

After that, double-click ZImager and it will run. ZImager is built on this Mac with Apple's tools. It is not notarized for distribution. That approval is required once.

## Helper on a Synology

Skip this if you only use Disk.

Server mode needs `zimage-helper` running on the NAS. The disk image does not include it. The Mac never opens `catalog.db`. Stop the DSM task before you replace the binary.

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
