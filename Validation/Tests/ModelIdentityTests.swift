import Foundation
import XCTest
@testable import ModelValidation

final class ModelIdentityTests: XCTestCase {
    func testMetadataWinsAndAdapterRoleIsRetained() {
        let result = ModelIdentity.identify(metadata: ["modelspec.architecture": "stable-diffusion-xl-v1-base"],
                                            tensors: ["unet.layer.lora_down.weight": [4, 16]])
        XCTAssertEqual(result.architecture, "stable-diffusion-xl-v1-base")
        XCTAssertEqual(result.kind, .lora)
        XCTAssertEqual(result.source, "文件元数据声明")
    }

    func testLanguageModelWithoutConfigDoesNotInventFamily() {
        let result = ModelIdentity.identify(metadata: [:], tensors: ["model.layers.0.self_attn.q_proj.weight": [16, 16]])
        XCTAssertEqual(result.kind, .text)
        XCTAssertNil(result.architecture)
    }

    func testSDCrossAttentionShapesIdentifyArchitecture() {
        for (dimension, expected) in [(768, "v1"), (1024, "v2"), (2048, "sdxl_base_v0.9"), (1280, "sdxl_refiner_v0.9")] {
            let result = ModelIdentity.identify(metadata: [:], tensors: ["down_blocks.1.attentions.0.transformer_blocks.0.attn2.to_k.weight": [16, UInt64(dimension)]])
            XCTAssertEqual(result.architecture, expected)
            XCTAssertEqual(result.kind, .image)
        }
    }

    func testLoKrIsNotMisclassifiedAsLoRA() {
        let result = ModelIdentity.identify(metadata: [:], tensors: ["layer.lokr_w1": [4, 4]])
        XCTAssertEqual(result.kind, .lokr)
        XCTAssertNil(result.architecture)
    }

    func testComponentAndUnknownRoles() {
        XCTAssertEqual(ModelIdentity.identify(metadata: [:], tensors: ["encoder.conv_in.weight": [4], "decoder.conv_out.weight": [4]]).kind, .vae)
        XCTAssertEqual(ModelIdentity.identify(metadata: [:], tensors: ["text_model.encoder.layers.0.weight": [4]]).kind, .textEncoder)
        XCTAssertNil(ModelIdentity.identify(metadata: [:], tensors: ["weight": [1]]).architecture)
    }

    func testLegacyLibraryMetadataRemainsDecodable() throws {
        let old = """
        {"id":"00000000-0000-0000-0000-000000000001","name":"old.gguf","byteCount":4,"importedAt":0,"format":"GGUF","validationNote":"legacy"}
        """
        let model = try JSONDecoder().decode(LocalModel.self, from: Data(old.utf8))
        XCTAssertNil(model.kind)
        XCTAssertNil(model.architectureSource)
    }

    func testFilenameNeverDeterminesSafetensorsArchitecture() throws {
        let header = try JSONSerialization.data(withJSONObject: ["weight": ["dtype": "F32", "shape": [1], "data_offsets": [0, 4]]])
        var length = UInt64(header.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(header)
        data.append(Data(repeating: 0, count: 4))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let result = try ModelFile.inspect(url, name: "Qwen-FLUX-LoRA.safetensors")
        XCTAssertNil(result.architecture)
        XCTAssertNil(result.adapter)
        XCTAssertEqual(result.kind, .unknown)
        data.removeLast()
        try data.write(to: url)
        XCTAssertThrowsError(try ModelFile.inspect(url, name: "truncated.safetensors"))
    }
}
