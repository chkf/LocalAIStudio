# AI Studio

A lightweight native iOS app for on-device AI, model files and device monitoring, built with SwiftUI and native Liquid Glass controls.

**Current implementation:** model management, the native **System** dashboard, appearance settings and a LiteRT-LM text inference path. **Gemma 4 E4B has not been verified on a physical iPhone in this project.** Image generation and system extensions remain planned.

## Changes in 0.1.2 (3)

- The home-screen display name is **AI Studio**. The repository, internal product name and bundle identifier remain unchanged so existing installations can retain their data.
- Files imports now use `UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)` with multiple selection. Select files, then confirm **Open**. Every returned URL is processed; cancellation before confirmation imports nothing.
- The system creates sandbox copies. The app moves those copies through its existing validated, atomic model-library staging area rather than reading the external provider URL in place or making a second full copy. Owned temporary copies remaining after errors/cancellation are reclaimed; ordinary user documents cannot enter the move/delete path.
- While the system is obtaining/copying a file, the picker remains responsible for that operation. The app can show checking/saving status only after its delegate receives the copies. System copying is not an app-controlled progress or resumable transfer.
- RAM now separates **estimated non-cache use** from file-backed/cache pages. The old `physicalMemory - free_count` figure included reclaimable caches and could look nearly full even without pressure. Raw counters remain in details; neither the estimate nor its complement is a guaranteed allocation budget.

The previous simulator tests used tiny files inside the app's exposed Debug Documents folder and did not require an Open button. Passing those tests did **not** reproduce the reported iOS 27.2/provider failure. The new UI test requires the picker to remain after selection, requires a hittable Open button, and then requires a new library entry. A separate cancel-after-selection test prevents accidental early import. The actual production picker factory is also tested. Files UI tests now select from a separate simulator-only **Import Fixtures** app, so the source is outside AI Studio’s sandbox. The production app no longer exposes a test-only Documents folder.

## Features and limits

- AI, Generate, System and Models tabs. Settings are in Models; system/light/dark appearance, larger text and accessibility settings are supported.
- System shows a clean RAM arc, app footprint, compact storage bar, App CPU, battery/charging, thermal state and actual AI task state. Tap for details, raw readings and inference records. The page uses SwiftUI, not an embedded HTML mockup.
- Memory estimate: `max(anonymous - purgeable, 0) + wired + compressor`, bounded by physical RAM. File-backed pages are shown separately. Inactive pages are **not** assumed fully reclaimable. These categories overlap; do not sum all detail rows. See Apple's [VM counter definitions](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/vm_statistics.h).
- App footprint and `os_proc_available_memory` are separate from system VM statistics. The latter is the app's changing process headroom, not free device RAM. Missing metrics remain unavailable. No invented system-wide GPU utilization, dedicated VRAM or Celsius temperature.
- One monitor samples every two seconds across tabs while active. Backgrounding retains a snapshot and stops sampling; returning resets the CPU baseline without inventing background samples. App CPU uses one core = 100%, so multithreaded work can exceed 100%.
- Model imports/downloads support search, deletion, size and bounded header inspection of LiteRT-LM, GGUF, TFLite and Safetensors. `.task`, `.ckpt` and `.bin` can be stored as unverified containers; no pickle is executed. Duplicate names are independent. Imported files are **not** certified runnable models.
- Public HTTPS/Hugging Face `resolve` links support progress, pause/cancel and conditional resume. Repository pages, authenticated repositories and CivitAI parsing are not implemented. Backgrounding pauses downloads. Continuation depends on the server and retained temporary data.
- The official pinned LiteRT-LM Swift package provides text loading, streaming, cancellation, unloading and conversation/input recovery. Native initialization itself is not immediately cancellable. One heavy task runs at a time; dynamic context is capped at 2,048 tokens and output at 512. Backgrounding requests cancellation/unload, not continued inference.
- Model load timing and engine-reported TTFT/tokens/s are recorded when available. File size is not treated as peak RAM; iOS can terminate a process before a memory warning.
- Image/audio input, actual local image generation, image history, applied LoRA/LoKr, WidgetKit, App Intents, Live Activities and continuous cross-app monitoring are **not implemented**.

## Build and verification

Windows/WSL2 can edit the project. GitHub Actions uses the Xcode 27 macOS runner. Pull requests to `main` build an unsigned Release IPA and run simulator unit/UI tests; pushes to `main` build the unsigned IPA. No signing credentials, model weights or deployment are included.

```sh
export GIT_LFS_SKIP_SMUDGE=1
xcodegen generate
xcodebuild -project LocalAIStudio.xcodeproj -scheme LocalAIStudio \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

The full simulator suite uses the fixtures prepared by [.github/workflows/ios.yml](.github/workflows/ios.yml). A separate `ImportFixtureHost` app exposes the source Documents folder; only simulator tests build/install it, and it is not included in the IPA. AI Studio uses the same document configuration in Debug and Release, with file sharing disabled in both. CI verifies that external source files are unchanged after import, cancellation and retry. The final IPA is checked for its visible display name and internal product metadata.

A new storage test adopts a **4 GB sparse test file** and checks that the inode survives the move, rather than allocating or copying 4 GB. This validates the storage path, not a provider transferring a real model. The Files UI fixture is a 1 MiB file containing only a 36-byte header and zero padding, not model weights. Actual build/test results belong in the PR and Actions run, not inferred from successful compilation.

Download the `LocalAIStudio-unsigned` artifact, extract its outer ZIP once, then pass the intact `LocalAIStudio-unsigned.ipa` to a local signing tool. The internal project/artifact name remains unchanged. CI verifies IPA integrity, executable/frameworks, icon assets and version metadata. The `LocalAIStudio-IconComposer` artifact contains layered icon sources and previews.

### Still required on the target iPhone

Verify a small file and the reported 3.66 GB `.litertlm` using the user's actual Files provider: select, Open, complete or receive an error, then inspect the new model row. Test cancellation/retry, source preservation and storage cleanup. Simulator success cannot certify this iOS 27.2/device/provider combination. Verify RAM counters and process budget, actual model load/generate/cancel/unload, server resume and accessibility on the device as well.

## Project references and licensing

Follow [AGENTS.md](AGENTS.md). The [product plan](docs/PLAN.md) describes the full roadmap, not a promise that every module is implemented. [Inference notes](docs/INFERENCE.md) record backend limits; [icon notes](docs/icon-composer.md) describe the compiled icon.

LiteRT-LM is pinned to official v0.18.1 and uses Apache-2.0; see [third-party notices](App/THIRD_PARTY_NOTICES.txt). Users obtain model weights under their own licenses. Sign the IPA locally; do not upload certificates, provisioning profiles, passwords or private keys. A third-party certificate does not guarantee restricted background entitlements.
