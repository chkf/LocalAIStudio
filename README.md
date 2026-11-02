# Local AI Studio

A lightweight native iOS app for on-device AI, model files and device monitoring, built with SwiftUI and the system's Liquid Glass controls.

**Current implementation:** a usable model library, public device metrics, appearance settings, and an actual LiteRT-LM text inference path. **Gemma 4 E4B has not yet been run on a physical iPhone in this project.** Image generation and system extensions remain planned.

![UI concept](docs/ui-mockup.svg)

## What works in this version

- **Native navigation:** AI, Generate, Device and Models tabs; system/light/dark appearance; native accessibility behavior and an opaque composer when Reduce Transparency is enabled.
- **Model library:** Files import, HTTPS file downloads, search, file size and metadata, and deletion. Duplicate names are stored independently.
- **File handling:** security-scoped access, coordinated and cancellable chunked imports, atomic model-directory commits, backup exclusion for weights, disk-space checks and preservation of original Files imports.
- **Downloads:** real progress, pause/cancel, saved requests and conditional resume data. Public Hugging Face resolve URLs work as direct links; repository pages, authentication and CivitAI parsing are not implemented. Entering the background pauses downloads. Resume depends on the server and system retaining the partial file.
- **Format recognition:** bounded inspection of LiteRT-LM, GGUF, TFLite and Safetensors headers. Architecture/quantization/adapter labels come from metadata or actual tensor keys. Files with .task, .ckpt and .bin extensions can be stored as explicitly unverified files; no pickle content is executed.
- **Text inference:** the official LiteRT-LM Swift package loads eligible .litertlm files, streams text, cancels native inference, unloads resources and restores conversation input/history after interruption. Model metadata is checked again by the engine before loading.
- **Performance:** real model load timing and engine-reported TTFT, output tokens and tokens/s, when available. No token counts are inferred from streamed chunks.
- **Device monitor:** total RAM, this app's memory footprint and CPU use, current process memory headroom, storage, battery/charging, thermal state and network path. Sampling runs only while Device is visible and the app is active.

## Current limits

- **An imported file is not a verified runnable model.** Only LiteRT-LM text inference is connected. The first load on each session explicitly identifies the unverified memory requirement.
- There is one active inference at a time. Switching or deleting an active model waits for cancellation and resource release. Native model initialization itself cannot be interrupted; a stop request is applied once initialization returns.
- Dynamic context is capped at 2,048 tokens; fixed-context models use their own configuration. Responses are capped at 512 tokens. There is no silent conversation truncation.
- App backgrounding requests cancellation and unload, and retains input for a new generation. It does not claim background inference or continuation at the last generated token.
- No image/audio input, actual image generation, image saving/history, LoRA application, LoKr support, WidgetKit, App Intents or Live Activities yet.
- Community checkpoint containers and adapter keys can be identified without being compatible with an installed engine.
- iOS memory budgets change. The app does not use weight-file size as a peak-memory estimate or promise freedom from jetsam.
- Device testing is still required for large Files/iCloud imports, real HTTPS resume servers, memory pressure and E4B generation. Simulator hardware metrics describe the runner Mac.

See [the product plan](docs/PLAN.md), [inference research and exact compatibility limits](docs/INFERENCE.md), and [development guidelines](AGENTS.md).

## Build and test

Develop from Windows/WSL2 and use the macOS GitHub Actions runner for Xcode builds. Every pull request runs:

1. XcodeGen project generation.
2. Unsigned iPhone Release compilation.
3. Packaging of LocalAIStudio-unsigned.ipa.
4. Unit tests and UI tests on an available iOS 26 iPhone simulator.
5. Upload of the IPA, test results/logs and UI screenshots.

The LiteRT-LM dependency is pinned to the official v0.18.1 commit rather than a floating branch; see [the dependency explanation](docs/INFERENCE.md). Model weights are not included.

On a Mac with Xcode 26 and XcodeGen:

```sh
export GIT_LFS_SKIP_SMUDGE=1
xcodegen generate
xcodebuild -project LocalAIStudio.xcodeproj -scheme LocalAIStudio \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project LocalAIStudio.xcodeproj -scheme LocalAIStudio \
  -destination 'platform=iOS Simulator,name=<available iPhone>' \
  CODE_SIGNING_ALLOWED=NO test
```

The current build/test outcome is recorded in the PR and its linked Actions run. The initial minimal app was built successfully on 2026-11-02; that result alone does not validate subsequent features.

## Signing and model licenses

CI produces an **unsigned** IPA. Sign it locally with your own P12 and matching provisioning profile. The repository and workflow do not need signing keys, passwords or certificates. Nothing is automatically installed or released.

A future widget requires its own matching profile/entitlements. A third-party signing certificate does not guarantee access to background GPU or other restricted capabilities.

LiteRT-LM uses Apache-2.0; the app includes [its license and attribution](App/THIRD_PARTY_NOTICES.txt). Model weights have separate licenses, are obtained by the user, and are not redistributed here.
