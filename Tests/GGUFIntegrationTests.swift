import XCTest
@testable import LocalAIStudio

final class GGUFIntegrationTests: XCTestCase {
    func testSupportedTextFormatsAreExplicit() {
        XCTAssertTrue(ModelFormat.litertLM.supportsTextGeneration)
        XCTAssertTrue(ModelFormat.gguf.supportsTextGeneration)
        XCTAssertFalse(ModelFormat.safetensors.supportsTextGeneration)
        XCTAssertFalse(ModelFormat.mediaPipe.supportsTextGeneration)
        XCTAssertFalse(ModelFormat.checkpoint.supportsTextGeneration)
        XCTAssertFalse(ModelFormat.binary.supportsTextGeneration)
    }

    func testGGUFModelDetailExplainsActualBackend() {
        let model = LocalModel(
            id: UUID(), name: "DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf", byteCount: 1_120_000_000,
            importedAt: .now, format: .gguf, architecture: "qwen2", quantization: "Q4_K_M",
            adapter: nil, validationNote: "GGUF header inspected"
        )
        XCTAssertTrue(model.compatibilityDescription.contains("llama.cpp"))
    }

    func testMissingGGUFModelReportsLoadFailure() async throws {
        let runtime = GGUFTextRuntime()
        let unavailable = URL(fileURLWithPath: "/unavailable/DeepSeek.gguf")
        do {
            _ = try await runtime.load(fileURL: unavailable, history: [], options: ChatPreferences())
            XCTFail("A missing model must not pretend to load")
        } catch GGUFTextRuntime.RuntimeError.modelLoad {
            // The native loader rejected the nonexistent GGUF before a chat could begin.
        }
        await runtime.unload()
    }
}
