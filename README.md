# AI Studio

A lightweight native iOS app for on-device AI, model files and device monitoring, built with SwiftUI and native Liquid Glass controls.

**Current implementation:** native System, model management, LiteRT-LM/GGUF/MLX text routing and a MediaGenerationKit Checkpoint image generation path. The user has verified a 3.66 GB LiteRT-LM model import and one generated reply on an iPhone; the newer GGUF, MLX and image pipelines still require device testing. System extensions remain planned.

## Model usability fixes

- Custom display names are editable in model details; the original filename and stable model ID remain unchanged. Existing library entries automatically refresh outdated identification once, preserving names and image settings.
- GGUF roles distinguish chat models from diffusion, text/vision encoders and adapters. Safetensors component tensors take precedence over parent-model metadata; SD/SDXL/FLUX aliases use the converter's architecture IDs.
- The image prompt fields now have explicit keyboard dismissal and interactive scroll dismissal.
- Image generation explicitly checks/downloads dependencies before inference, showing the component filename and byte progress. `fromPretrained` / local `generate` alone do not download them. The required pinned catalog and sampling JSON are included in the app bundle; see [catalog attribution](docs/image-catalog-resources.md).
- **模型与配套组件** lists VAE and encoder dependencies, local/cache status, and lets users bind imported compatible Draw Things `.ckpt` components. Settings persist per model; standard files are cached separately. Custom files use private runtime aliases so catalog checksum handling cannot replace them.
- A Draw Things checkpoint with a custom filename can be assigned a matching base profile. Raw PyTorch `.ckpt`, external-data checkpoints and unknown/incompatible profiles are rejected with actionable errors. A matching profile/container is still not proof of weight compatibility.
- SD1/SD2/SDXL conversion accepts compatible raw Safetensors VAE and text encoders (SDXL Base needs both CLIP-L and bigG when absent from the checkpoint). Other architectures use standard or preconverted Draw Things components; arbitrary raw VAE/encoder conversion is not supported.
- These fixes were checked locally without triggering GitHub Actions. The SwiftUI interaction, iOS compilation and actual image inference still need device validation.

## Model identification and processing in 0.5.0 (7)

- Model details show architecture, role and the source of that identification. GGUF metadata and MLX `config.json` provide architecture declarations; Safetensors checks tensor names/shapes against metadata. Shared chat tensor layouts are deliberately not labelled as a specific Llama/Qwen/Gemma family without configuration. Existing entries can be re-inspected.
- A raw image Safetensors model can be converted using the pinned Draw Things `ModelOp.ModelImporter`. Choose the matching base configuration (SD1.5, SD2.1, SDXL, FLUX.1 dev/schnell/Krea, Qwen Image, Z Image or FLUX.2 klein 4B profiles exposed in the UI). The importer independently checks the architecture; unsupported image/edit inputs fail explicitly. Embedded SD text encoders/VAE are preserved; separate compatible SD VAE and text encoders may be selected. This is not universal Safetensors support.
- Safetensors LoRAs can be converted locally with `LoRAImporter`, then selected with a weight in the image page. Generation checks the actual converted architecture against the base model before attaching the LoRA. LoKr and language-model LoRAs are not part of this image conversion path.
- Converted image base models offer a separate 8-bit Q8P variant, using the existing NNC codec one tensor at a time. Non-matrix parameters and tensors identified by stored norm/embedding/bias/scale/shift names retain FP16; companion files remain unchanged. Quantization affects the main diffusion weights, not total app RAM or all model components.
- Conversions are staged and committed as new library entries. Originals are retained; interrupted outputs are cleaned. Cancellation of synchronous upstream import may finish only after the current conversion returns; the app stays busy until then. Chat/image inference is stopped before model processing.
- Converted bundles retain model metadata and local components. The app explicitly prepares missing standard resources in its separate runtime cache before generation. Models and LoRAs are linked into that runtime only for the active generation. The Models menu can clear downloaded image resources while no image/model-processing task is running.
- MLX is linked through the embedded `MLXBackend` framework, keeping its Metal C++ implementation separate from NNC's. The app does not also link the MLX packages directly. CI checks the framework and Metal shader bundle in the IPA and enables the pinned MLX macro for unattended Xcode builds. Portable metadata/identification tests run separately; simulator tests are explicitly skipped when the pinned llama XCFramework lacks simulator slices. This does not count as passing simulator or device inference tests.

This release still needs an iPhone check with real model/LoRA files: conversion, comparison with/without LoRA, quantized output quality, cancellation and peak memory. Chat-model conversion/quantization is not provided by these Draw Things image tools.

## Safetensors and Checkpoint support in 0.4.0 (6)

- **MLX Swift LM:** Import a *complete model folder* from Files using "导入 MLX 模型文件夹". The folder must contain `config.json` (with a supported `model_type`), `tokenizer.json` and one or more `.safetensors` files. It is stored atomically and appears beside LiteRT-LM and GGUF in AI chat. MLX Swift LM 3.32.3 handles local model/tokenizer loading and streaming on Apple Metal; Chat Settings sampling and system prompt carry through. A lone Safetensors file or arbitrary PyTorch repository is **not** a runnable model.
- **Local image generation:** The 生图 tab now offers prompt/negative prompt, image size, steps, cancellation, PNG output and the system share sheet. The backend is MediaGenerationKit, pinned to `37e0b700...` and licensed LGPL-3.0. It attempts to resolve **supported Draw Things checkpoints** already imported in the model library, while additional companion resources may still be required. Unsupported arbitrary PyTorch/Stable Diffusion `.ckpt` or raw diffusion `.safetensors` should fail explicitly instead of pretending to generate.
- The model library distinguishes complete MLX model bundles, standalone `.safetensors` weight files and image Checkpoints. Folder imports reject symbolic links and incomplete manifests; the user's original documents are preserved.
- Only one heavyweight chat or image task runs at a time. Switching between image generation and chat requests cancellation/unloading of the other runtime.
- This is **a source and integration milestone**, not a real-device compatibility claim. Actual image checkpoints, the MLX model architectures and peak memory have not yet been tested on the target iPhone. No weight files are redistributed.

## GGUF / DeepSeek support in 0.3.0 (5)

- Added a second, real local text runtime based on llama.cpp (pinned via llama.swift 2.10549.0, upstream b10549 XCFramework). Single-file **GGUF text models** and LiteRT-LM appear in one model selector, with shared streaming chat, cancellation, unloading, history persistence, system prompts, CPU/Metal selection, sampler controls and measured performance.
- Each GGUF response applies the model's embedded chat template to the current chat history, then tokenizes, prefills and streams token pieces using the native llama.cpp APIs. Unsupported or absent chat templates fail clearly. Multi-part models, custom Jinja-only templates and external multimodal projectors are not claimed to work.
- The GGUF runtime cancels decoding via a thread-safe flag rather than waiting for the actor to finish its synchronous C calls. A single heavyweight model remains active at a time. Saving an imported GGUF file does not guarantee it is supported or fits in memory.
- Recommended first compatibility target: `bartowski/DeepSeek-R1-Distill-Qwen-1.5B-GGUF` file `DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf` (~1.12 GB); **model weights are not included**. iPhone inference, CPU/Metal throughput, memory peak and C++ cancellation still require device verification.
- `.safetensors`, `.ckpt`, `.tflite`, and other formats still require their own actual engines or complete model directories; they remain storage/inspection-only. GGUF thinking follows the model's chat template; the speculative decoding option is explicitly rejected for GGUF rather than silently ignored.

## Changes in 0.2.0 (4)

- Chat Settings (the AI page's options menu) apply real LiteRT-LM controls: output-token limit, Top-K/Top-P, temperature, supported CPU/Metal backend selection, optional thinking, optional speculative decoding, and a system prompt. These settings persist across launches. Changing the settings unloads the active model so the next request uses the new configuration. Not all models support thinking, speculative decoding or every accelerator; unsupported requests surface the engine error.
- Audio uses Apple's on-device APIs rather than pretending bundled Kokoro/Parakeet models exist: tap the microphone to transcribe into the message field with permission, choose a locale and system voice, and enable optional automatic spoken replies or speak one reply from its context menu. Recognition requires on-device support for the selected locale. Recording starts only after explicit user action.
- Settings in the Models tab now include a Chinese/English app language selector and a five-color accent selector. Chinese remains the default; English localization covers common navigation, model, chat, settings and device controls.
- Removed the always-visible line under the chat log, including "model unloaded" and completed status messages. Task state remains available in System.
- Visual token budget is not exposed before image input is implemented. Neither audio-model selection nor image input is silently simulated.

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
- Image-to-chat input, direct audio-to-model input, separately downloaded Kokoro/Parakeet engines, image history/gallery, LoKr and chat-adapter application, universal Checkpoint conversion, WidgetKit, App Intents, Live Activities and continuous cross-app monitoring are **not implemented**. Image LoRA and compatible Safetensors conversion are described above. Native device dictation and speech playback are separate from model audio input.

## Build and verification

Windows/WSL2 can edit the project. GitHub Actions uses the Xcode 27 macOS runner. Pull requests to `main` run portable logic tests, build an unsigned Release IPA and run simulator unit/UI tests only when the pinned inference frameworks include simulator slices; pushes to `main` run the logic tests and build the unsigned IPA. No signing credentials, model weights or deployment are included.

```sh
export GIT_LFS_SKIP_SMUDGE=1
xcodegen generate
xcodebuild -skipMacroValidation -project LocalAIStudio.xcodeproj -scheme LocalAIStudio \
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


### 本地语音朗读

在「模型 → 语音模型」或「对话设置 → 语音模型与朗读」中，下载 Kokoro v1.0 INT8 中英文模型（约 151 MB），或导入自己下载并解压的 sherpa-onnx Kokoro v1.0 文件夹。
支持文件：`model.int8.onnx` 或 `model.onnx`、`voices.bin`、`tokens.txt`、`lexicon-us-en.txt`、`lexicon-zh.txt`；可选中文数字／日期／电话 FST 和 LICENSE 会一并复制。原始 PyTorch／MLX 权重、单独的 ONNX 文件、其他 TTS 架构不兼容。

添加后选择模型、音色编号与语速，可试听，也用于消息菜单的「朗读」与「自动朗读回复」。系统语音仍是默认选项。Kokoro 合成前释放聊天模型，逐段生成并播放，结束或取消后释放 TTS 引擎；后台／内存警告会停止朗读。再次聊天会重新加载聊天模型。此版本不包含声音克隆。

引擎固定为 sherpa-onnx v2.0.1，CPU 推理；内置下载固定上游模型快照，校验全部下载文件 SHA-256，取消或失败清理 staging。模型权重不随应用分发，使用须遵守模型来源页面及包内许可证。


### Chat 联网工具

在「对话设置 → 联网工具」开启「允许联网」（默认关闭）。搜索使用 DuckDuckGo 公开 HTML 搜索页，无需注册或 API Key；遇到验证码、访问限制或页面结构变化时会明确报错，不尝试绕过。网页读取同样无需 Key，不使用浏览器登录态，不执行网页脚本，不支持登录墙、PDF 或纯 JavaScript 页面。

开启后，本地模型通过严格 JSON 请求选择 `web_search`、`read_webpage` 或直接回答；App 实际执行请求，将有限的搜索摘要／正文节选交回模型。每轮最多 3 次联网调用，显示调用记录和实际来源链接，停止生成会取消网络请求。LiteRT-LM 的工具规划阶段关闭思考；最终回答保留用户设置。GGUF／MLX 复用文本接口，能否输出有效工具 JSON 取决于模型，尚未完成各架构真机兼容性验收。

模型推理继续在本机运行，但搜索词和读取的链接会发送到对应服务。网页结果作为不可信资料传入；工具只允许搜索和公开 HTTPS 读取，拒绝本机／私网域名解析、非标准端口、URL 内嵌凭证；逐跳检查重定向，搜索 Key 不随重定向转发。响应限制 1 MiB，正文按节选送入上下文。联网模式请求最多 8192 Token 的输入输出上下文（受模型上限限制），长对话仍可能超出模型窗口。

这一版没有接入文件、相册、日历、提醒事项、快捷指令或远程 MCP 工具。
