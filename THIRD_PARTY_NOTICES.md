# Third-Party Notices

CarbocationLocalSpeech includes and publishes artifacts derived from third-party software. This file is informational and does not replace upstream license files.

## whisper.cpp / ggml

- Project: `whisper.cpp` / `ggml`
- License: MIT
- Upstream copyright: `Copyright (c) 2023-2026 The ggml authors`
- Upstream source in this repository: `Vendor/whisper.cpp`
- Upstream license file: `Vendor/whisper.cpp/LICENSE`

`Sources/whisper/include` contains synced public headers from `whisper.cpp` / `ggml` for the SwiftPM `whisper` module. Generated binary `whisper.xcframework` artifacts, including files built under `Vendor/whisper-artifacts`, are built from upstream `whisper.cpp` / `ggml` sources and remain subject to the upstream MIT license terms.

## Whisper Model Weights

Whisper model weights are not bundled in this repository. Apps may import or download model weights from external sources; those weights remain subject to the license terms from their source or model provider.
