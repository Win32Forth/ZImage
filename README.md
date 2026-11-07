# ZImage

ZImage is a macOS editor for still photographs, plus a library app and a small catalog helper for a Synology share.

The editor opens a photo, adjusts it, and saves a `.zimg` edit log beside a preview. Dust and scratch repair, crop, tone, color, and geometry are in that window. ZImage Library is the separate catalog window. The helper in `Helper/` is the only program that writes the catalog database.

`DESIGN.md` is the plan. `STATUS.md` is the iteration log, newest first.

## Build

The Xcode command-line tools are the default on this machine. Point the build at Xcode:

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
cd /path/to/ZImage
xcodebuild -project ZImage.xcodeproj -scheme ZImage -destination 'platform=macOS,arch=arm64' build
```

The library scheme is `ZImageLibrary`. The helper is Go and is cross-compiled for the NAS. `Helper/zimage-helper` is a local build product and is not in this repo.
