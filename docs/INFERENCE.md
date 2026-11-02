# 推理接入与验证边界

核实日期：2026-11-02。这里区分**上游提供的能力**、**本项目已接线的代码**和**真机验证**。

## LiteRT-LM：已接入文本路径，真机验收待完成

Google 提供官方 SwiftPM 产品 `LiteRTLM`，最低 iOS 15，Swift API 标为 Early Preview。原生 API 提供 Metal/CPU、流式输出、取消和模型元数据读取；Gemma 4 E4B 有官方链接的 `.litertlm` 发布文件。[Swift 指南](https://developers.google.com/edge/litert-lm/swift)、[E4B 模型卡](https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm)。

本项目锁定上游提交 [`c642af8627ebdab909d7ba0e33a121d601b3c255`](https://github.com/google-ai-edge/LiteRT-LM/commit/c642af8627ebdab909d7ba0e33a121d601b3c255)，对应 v0.19.0 Swift 包修复。原因是 [v0.19.0 标签的 Package.swift](https://github.com/google-ai-edge/LiteRT-LM/blob/v0.19.0/Package.swift) 仍引用 v0.18.1 二进制，而这一提交将二进制与新版 C API 对齐。使用固定提交和上游 XCFramework 校验和，避免跟随 `main` 漂移。CI 按[上游说明](https://github.com/google-ai-edge/LiteRT-LM/blob/c642af8627ebdab909d7ba0e33a121d601b3c255/samples/ios_and_mac/README.md)设置 `GIT_LFS_SKIP_SMUDGE=1`，不拉取不相关平台的预编译大文件。

### 当前实现

- 用户导入/下载的 `.litertlm` 文件交给原生 `ModelInfo` 再验证文本模态和后端。下载或识别文件头不等于通过运行验证。
- 单个 `TextRuntime` actor 持有原生 Engine/Conversation，加载、流式初始化及释放在 UI actor 之外执行。仅使用模型声明的 Metal 或 CPU 后端。
- 同时只有一个生成任务。动态上下文最多 2,048 token，单次输出最多 512 token，暂不启用 thinking、视觉、音频或 LoRA。已有对话不做静默截断；超出引擎上下文会明确报错。
- 取消调用原生 `Conversation.cancel()`，等待流的终止回调再卸载。原生初始化没有取消 API，因此加载中停止需等待初始化返回。
- 上游没有显式 Engine.close；必须先释放 Conversation，再释放 Engine，原生对象由其 `deinit` 销毁。[生命周期源码](https://github.com/google-ai-edge/LiteRT-LM/blob/c642af8627ebdab909d7ba0e33a121d601b3c255/swift/Engine.swift)、[流与取消源码](https://github.com/google-ai-edge/LiteRT-LM/blob/c642af8627ebdab909d7ba0e33a121d601b3c255/swift/Conversation.swift)。
- 加载耗时使用单调时钟测量。TTFT、tokens/s 和输出 token 数只采用引擎实际返回的 benchmark 数据；没有数据时留空，不把流式文本块当 token。
- 生成前原子保存输入、模型选择和已完成对话。被系统终止后恢复输入，不宣称从原 token 继续。取消后的部分文字标为中断，不作为后续完整对话传给模型。
- 读取当前进程的可分配内存预算；不把磁盘文件大小转换成峰值内存预测。未测量的文件仍存在 jetsam 风险，单任务、卸载与内存警告处理无法保证零闪退。

LiteRT-LM 代码采用 [Apache-2.0](https://github.com/google-ai-edge/LiteRT-LM/blob/c642af8627ebdab909d7ba0e33a121d601b3c255/LICENSE)。模型权重遵循各自发布页的许可，不打包进 IPA。

### 仍需真机验证

未下载多 GB 权重，也未在本轮运行 E4B。编译和无权重测试不能替代以下验收：

1. 在目标 iPhone 导入模型卡中的实际 `.litertlm` 文件，确认 Metal/CPU 路径成功加载、三轮对话与上下文重建。
2. 记录首次/再次加载、首 token、真实吞吐、App footprint 和系统剩余预算；测试取消后重新生成、切换模型和卸载后的内存回落。
3. 测试加载中取消、生成中取消、切到后台、系统终止后的输入恢复，以及长输入超出上下文的错误提示。
4. 在以上结果完成前，模型仍标为“可尝试加载 / 尚未真机验证”，不宣称 Gemma 4 E4B 已跑通。

## MediaGenerationKit：已核实，尚未接入

上游[包清单](https://github.com/drawthingsai/media-generation-kit/blob/8868a9685d9c299816f43ef53efd455ffca437f0/Package.swift)声明 iOS 16+，通过固定 revision 依赖 `draw-things-community`。它不是不存在的占位 SDK；公开 API 包括 `MediaGenerationPipeline.fromPretrained`、`.local(directory:)`、生成进度与结果写入、`MediaGenerationEnvironment` 的模型解析/下载，以及本地转换用 `LoRAImporter`。[官方 README](https://github.com/drawthingsai/media-generation-kit/blob/8868a9685d9c299816f43ef53efd455ffca437f0/README.md)。

本轮不把未经验证的依赖、模型和下载转换链路塞进主 App。上游示例中的 `flux_2_klein_4b_q8p.ckpt` 属于其模型体系，不能据此推断任意同扩展名的社区 Checkpoint、SDXL、Z-Image、Krea 或 LoKr 都能加载。上游说明采用 LGPLv3，接入时需要保留相应许可与第三方声明并确认实际分发方式。

下一步用固定版本接入**一个**上游支持的模型，获取完整依赖，在真机完成本地加载 → 生成 → 取消 → 保存 → 释放内存。先测该架构的加载/采样/VAE 解码峰值，再开放兼容社区模型。LoRA 必须以实际文件验证转换及效果；LoKr 仍是研究项。

## 本轮未覆盖

图像生成、图片输入、LoRA 应用、LoKr、后台持续计算、WidgetKit、Live Activities 和 App Intents 尚未实现。当前进入后台会请求停止并卸载，不启用无关后台模式。后续分别验证系统 API、签名权限及模型资源后再接线。
