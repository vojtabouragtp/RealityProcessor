# Reality Processor v0.1

Native macOS SwiftUI proof-of-concept for ingesting a real-estate shoot and detecting 5-shot HDR brackets (-2, -1, 0, +1, +2 EV).

## Run
1. Open `RealityProcessor.xcodeproj` in Xcode on macOS.
2. Select the `RealityProcessor` scheme.
3. Build & Run.
4. Click **Vybrat složku**, choose the folder containing RAW files, then click **Analyzovat**.

## Current scope
- Folder picker / drag-and-drop folder support
- RAW/JPEG/TIFF file discovery (recursive)
- EXIF capture time and exposure-bias extraction using ImageIO
- Detection of 5-shot bracket sequences close to -2/-1/0/+1/+2 EV
- Confidence / review flagging
- Overview: RAW count, detected HDR sets, ungrouped files

## Next milestone
- Create project folder structure
- Copy/rename original files
- Build Lightroom handoff / HDR-merge integration


## v0.6
- DJI DNG bracket detection now derives relative EV from shutter/ISO/aperture when ExposureBiasValue is missing or wrong.
- DJI filename timestamp is parsed directly.
- Sequential 3-shot DNG fallback for AEB bursts.
