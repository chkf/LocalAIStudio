# Local AI Studio

A lightweight, native iOS app for **on-device AI**, image generation, model management, device monitoring, widgets, and Shortcuts.

**Status:** Minimal SwiftUI four-tab starter and a basic on-device status snapshot are checked in. The starter compiled in GitHub Actions on 2026-11-02; iPhone installation and on-device testing have not yet been verified. AI inference, background generation, and widgets are not implemented.

![UI concept](docs/ui-mockup.svg)

## Goals

- **Native UI:** Swift + SwiftUI, Liquid Glass, follow system light/dark appearance and accessibility settings.
- **On-device models:** a modular model library, starting with Gemma and image-generation backends; downloaded files are not automatically runnable.
- **Image generation:** supported community checkpoints and adapters (LoRA; LoKr is a research target), image-to-image and editing where engines permit.
- **Model downloads:** HTTPS direct links first, later Hugging Face / CivitAI repository parsing, resuming and validation.
- **Device monitor:** public system metrics and **this app's** inference performance; no private API or fake global GPU/VRAM metrics.
- **Widgets & Shortcuts:** performance snapshots, task entry points, App Intents; Live Activities for eligible active tasks.
- **Stability:** handle real memory, disk, cancellation and background-execution risks without excessive defensive architecture.

See [the project plan](docs/PLAN.md) and [development guidelines](AGENTS.md).

## Build and signing approach

The repository includes an XcodeGen spec (`project.yml`) and a GitHub Actions workflow (`.github/workflows/ios.yml`) for an unsigned IPA. Open the **Actions** tab to inspect build results; the first unsigned IPA build succeeded on 2026-11-02.


Development from Windows 11 + WSL2, with an Xcode/macOS build environment (e.g. GitHub Actions). Build an **unsigned IPA**, then sign **locally** with your own P12 private key and matching provisioning profile. Signing material is not needed in the repository or CI.

An app extension (including a widget) needs its own matching App ID/profile and appropriate entitlements. Background GPU inference depends on system support and entitlements and cannot be guaranteed by a third-party certificate.

## Scope and honesty

This repository is being initialized. The roadmap describes **targets**, not completed features. True iOS compilation, memory usage, plugin compatibility and on-device model performance must be validated before claiming support.

Model weights are downloaded by the end user and are not redistributed by this repository. Respect each upstream project's license.
