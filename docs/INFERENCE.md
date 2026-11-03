# 推理接入与验证边界

核实日期：2026-11-02。这里区分**上游提供的能力**、**本项目已接线的代码**和**真机验证**。

## LiteRT-LM：已接入文本路径，真机验收待完成

Google 提供官方 SwiftPM 产品 `LiteRTLM`，最低 iOS 15，Swift API 标为 Early Preview。原生 API 提供 Metal/CPU、流式输出、取消和模型元数据读取；Gemma 4 E4B 有官方链接的 `.litertlm` 发布文件。[Swift 指南](https://developers.google.com/edge/litert-lm/swift)、[E4B 模型卡](https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm)。

本项目锁定官方 **v0.18.1** 发布提交 [`bda624851d74be34d4e1f7fac1fc4155939539c7`](https://github.com/google-ai-edge/LiteRT-LM/commit/bda624851d74be34d4e1f7fac1fc4155939539c7)。[该版本的 Package.swift](https://github.com/google-ai-edge/LiteRT-LM/blob/v0.18.1/Package.swift)直接引用同版本 XCFramework 及其校验和。选择依据来自实际编译：最初尝试的 v0.19.0 包更新提交 `c642af86` 在 [Actions 构建](https://github.com/chkf/LocalAIStudio/actions/runs/41417631648)中因上游 Swift 源码调用二进制头文件尚未提供的 `litert_lm_speculative_decoding_config_set_lenience` 而失败。本项目不修改下载的依赖源码或忽略未解析符号，改用同一发布版本的源码与二进制。CI 设置 `GIT_LFS_SKIP_SMUDGE=1`，避免拉取不相关平台的预编译大文件。

### 当前实现

- 用户导入/下载的 `.litertlm` 文件交给原生 `ModelInfo` 再验证文本模态和后端。下载或识别文件头不等于通过运行验证。
- 单个 `TextRuntime` actor 持有原生 Engine/Conversation，加载、流式初始化及释放在 UI actor 之外执行。仅使用模型声明的 Metal 或 CPU 后端。
- 同时只有一个生成任务。默认动态上下文 2,048 token、单轮输出 512 token；现在可配置单轮输出上限、采样参数、CPU/Metal 后端、系统提示词，以及模型支持时的 thinking/推测解码。动态上下文大小会随输出预算调整但不超过模型声明的上限；超出引擎上下文会报错，不做静默截断。视觉输入、模型原生音频输入和 LoRA 尚未接入。iOS 系统语音转写/朗读不等于 LiteRT-LM 音频模型。
- 取消调用原生 `Conversation.cancel()`，等待流的终止回调再卸载。原生初始化没有取消 API，因此加载中停止需等待初始化返回。
- 上游没有显式 Engine.close；必须先释放 Conversation，再释放 Engine，原生对象由其 `deinit` 销毁。[生命周期源码](https://github.com/google-ai-edge/LiteRT-LM/blob/v0.18.1/swift/Engine.swift)、[流与取消源码](https://github.com/google-ai-edge/LiteRT-LM/blob/v0.18.1/swift/Conversation.swift)。
- 加载耗时使用单调时钟测量。TTFT、tokens/s 和输出 token 数只采用引擎实际返回的 benchmark 数据；没有数据时留空，不把流式文本块当 token。
- 生成前原子保存输入、模型选择和已完成对话。被系统终止后恢复输入，不宣称从原 token 继续。取消后的部分文字标为中断，不作为后续完整对话传给模型。
- 读取当前进程的可分配内存预算；不把磁盘文件大小转换成峰值内存预测。未测量的文件仍存在 jetsam 风险，单任务、卸载与内存警告处理无法保证零闪退。

LiteRT-LM 代码采用 [Apache-2.0](https://github.com/google-ai-edge/LiteRT-LM/blob/v0.18.1/LICENSE)。模型权重遵循各自发布页的许可，不打包进 IPA。

### 仍需真机验证

未下载多 GB 权重，也未在本轮运行 E4B。编译和无权重测试不能替代以下验收：

1. 在目标 iPhone 导入模型卡中的实际 `.litertlm` 文件，确认 Metal/CPU 路径成功加载、三轮对话与上下文重建。
2. 记录首次/再次加载、首 token、真实吞吐、App footprint 和系统剩余预算；测试取消后重新生成、切换模型和卸载后的内存回落。
3. 测试加载中取消、生成中取消、切到后台、系统终止后的输入恢复，以及长输入超出上下文的错误提示。
4. 在以上结果完成前，模型仍标为“可尝试加载 / 尚未真机验证”，不宣称 Gemma 4 E4B 已跑通。

## llama.cpp / GGUF 文本后端（新增）

采用 `mattt/llama.swift` 2.10549.0（llama.cpp b10549 官方 XCFramework，MIT 许可）。这是 iOS/Metal 上实际使用的第二个文本引擎，不是只识别文件头或占位接口。

- 在模型库中选择单文件 `.gguf`，文本聊天将走 llama.cpp；原 `.litertlm` 仍走 LiteRT-LM。
- 使用 GGUF 自带聊天模板构造 system/user/assistant 多轮输入，预填充按 512 token 分块，逐 token 流式解码；每轮重建上下文，超出窗口明确报错，不静默截断。
- 支持 CPU/Metal、Top-K、Top-P、Temperature、最大输出 Token、取消、释放模型/上下文和实际时间/速度统计。
- 不宣称兼容所有 GGUF 架构、模板、多分片或视觉音频附属文件。推测解码开关目前只接 LiteRT-LM，对 GGUF 会报明确不支持。
- **仍需真机实测** DeepSeek-R1-Distill-Qwen-1.5B Q4_K_M 的加载、首 token、连续生成、多轮、取消和卸载；IPA 编译通过不等于这些功能已在目标设备通过。

## MLX Swift LM：完整 Safetensors 模型目录

- 锁定 `mlx-swift-lm` 3.32.3，以及 Hugging Face tokenizer 兼容包。通过 `LLMModelFactory.shared.loadContainer(from:using:)` 从已导入的完整本地目录读取模型，不按独立 `.safetensors` 后缀推断兼容性。
- 模型文件夹必须包含 `config.json` 的 `model_type`、`tokenizer.json`、至少一份 `.safetensors`。导入会检查清单、拒绝符号链接、原子入库，但真正架构/权重兼容性由 MLX 加载时验证。
- 推理支持多轮消息、系统提示词、Top-K/Top-P/温度、生成长度、流式文本、停止、卸载与真实统计。MLX 使用 Apple Metal；强制 CPU 或当前未接线的推测/思考开关会明确报错。
- 本轮只接文本语言模型。VLM 图片输入、LoRA、任意 Safetensors 格式转换需要按架构继续验证。

## MediaGenerationKit：Checkpoint 生图（新增）

- 锁定 `drawthingsai/media-generation-kit` 提供的 LGPL-3.0 SwiftPM 接口，使用 `MediaGenerationPipeline.fromPretrained(... backend: .local(directory:))` 加载 **ModelZoo 能识别的**本地 `.ckpt` 模型。
- 生图页提供提示词、负面提示词、尺寸、步数，异步调用 `generate`、处理取消和保存 PNG；通过系统共享面板导出结果。
- 用户下载的任意 `.ckpt`、`.safetensors` 不一定是完整生图模型。尚未实现通用原始 SD/FLUX 权重转换或 LoRA 绑定；不执行 PyTorch pickle 内容。
- 第三方 LGPL 许可和组件出处保留在 App 第三方声明，源码及构建方式保持公开。

## MediaGenerationKit：原始调研与边界

上游[包清单](https://github.com/drawthingsai/media-generation-kit/blob/8868a9685d9c299816f43ef53efd455ffca437f0/Package.swift)声明 iOS 16+，通过固定 revision 依赖 `draw-things-community`。它不是不存在的占位 SDK；公开 API 包括 `MediaGenerationPipeline.fromPretrained`、`.local(directory:)`、生成进度与结果写入、`MediaGenerationEnvironment` 的模型解析/下载，以及本地转换用 `LoRAImporter`。[官方 README](https://github.com/drawthingsai/media-generation-kit/blob/8868a9685d9c299816f43ef53efd455ffca437f0/README.md)。

此前调研阶段未接入；本次已增加最小本地 Checkpoint 生图管线，但仍不能把它理解为任意格式通用的转换器。上游示例中的 `flux_2_klein_4b_q8p.ckpt` 属于其模型体系，不能据此推断任意同扩展名的社区 Checkpoint、SDXL、Z-Image、Krea 或 LoKr 都能加载。上游说明采用 LGPLv3，接入时需要保留相应许可与第三方声明并确认实际分发方式。

下一步用固定版本接入**一个**上游支持的模型，获取完整依赖，在真机完成本地加载 → 生成 → 取消 → 保存 → 释放内存。先测该架构的加载/采样/VAE 解码峰值，再开放兼容社区模型。LoRA 必须以实际文件验证转换及效果；LoKr 仍是研究项。

## 本轮未覆盖

图像生成、图片输入、LoRA 应用、LoKr、后台持续计算、WidgetKit、Live Activities 和 App Intents 尚未实现。当前进入后台会请求停止并卸载，不启用无关后台模式。后续分别验证系统 API、签名权限及模型资源后再接线。
