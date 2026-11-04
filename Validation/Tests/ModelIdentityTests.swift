import Foundation
import XCTest
@testable import ModelValidation

final class ModelIdentityTests: XCTestCase {
    func testMetadataWinsAndAdapterRoleIsRetained() {
        let result = ModelIdentity.identify(metadata: ["modelspec.architecture": "stable-diffusion-xl-v1-base"],
                                            tensors: ["unet.layer.lora_down.weight": [4, 16]])
        XCTAssertEqual(result.architecture, "sdxl_base_v0.9")
        XCTAssertEqual(result.kind, .lora)
        XCTAssertEqual(result.source, "文件元数据声明；适配器张量确认角色")
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

    func testFluxVariantsAndQwenImageStayDistinctFromChatModels() {
        for (key, expected) in [
            ("double_blocks.18.img_attn.qkv.weight", "flux1"),
            ("single_blocks.39.linear1.weight", "flux2"),
            ("single_blocks.23.linear1.weight", "flux2_9b"),
            ("single_blocks.19.linear1.weight", "flux2_4b"),
            ("transformer_blocks.59.txt_mlp.weight", "qwen_image")
        ] {
            let result = ModelIdentity.identify(metadata: [:], tensors: [key: [16, 16]])
            XCTAssertEqual(result.architecture, expected)
            XCTAssertEqual(result.kind, .image)
        }
    }

    func testFullFluxLayoutsDoNotCollideWithSmallerVariants() {
        for prefix in ["", "model.diffusion_model."] {
            var flux1 = Dictionary(uniqueKeysWithValues: (0..<38).map {
                ("\(prefix)single_blocks.\($0).linear1.weight", [UInt64(16), 16])
            })
            for index in 0..<19 { flux1["\(prefix)double_blocks.\(index).img_attn.qkv.weight"] = [16, 16] }
            for metadata in [[:], ["modelspec.architecture": "FLUX.1-dev"]] {
                let result = ModelIdentity.identify(metadata: metadata, tensors: flux1)
                XCTAssertEqual(result.architecture, "flux1")
                XCTAssertEqual(result.kind, .image)
            }
        }
        let diffusers = Dictionary(uniqueKeysWithValues: (0..<38).map {
            ("single_transformer_blocks.\($0).proj_mlp.weight", [UInt64(16), 16])
        })
        XCTAssertEqual(ModelIdentity.identify(metadata: [:], tensors: diffusers).architecture, "flux1")
        for (count, expected) in [(40, "flux2"), (24, "flux2_9b"), (20, "flux2_4b")] {
            for pattern in ["single_blocks.%d.linear1.weight", "single_transformer_blocks.%d.attn.to_qkv_mlp_proj.weight"] {
                let tensors = Dictionary(uniqueKeysWithValues: (0..<count).map {
                    (String(format: pattern, $0), [UInt64(16), 16])
                })
                XCTAssertEqual(ModelIdentity.identify(metadata: [:], tensors: tensors).architecture, expected)
            }
        }
    }

    func testComponentAndUnknownRoles() {
        XCTAssertEqual(ModelIdentity.identify(metadata: [:], tensors: ["encoder.conv_in.weight": [4], "decoder.conv_out.weight": [4]]).kind, .vae)
        XCTAssertEqual(ModelIdentity.identify(metadata: [:], tensors: ["text_model.encoder.layers.0.self_attn.q_proj.weight": [16, 16]]).kind, .textEncoder)
        XCTAssertEqual(ModelIdentity.identify(metadata: [:], tensors: ["shared.weight": [4], "encoder.block.0.weight": [4], "decoder.block.0.weight": [4]]).kind, .textEncoder)
        XCTAssertEqual(ModelIdentity.identify(metadata: ["modelspec.architecture": "QwenImage"], tensors: [:]).kind, .image)
        XCTAssertNil(ModelIdentity.identify(metadata: [:], tensors: ["weight": [1]]).architecture)
    }

    func testLegacyLibraryMetadataRemainsDecodable() throws {
        let old = """
        {"id":"00000000-0000-0000-0000-000000000001","name":"old.gguf","byteCount":4,"importedAt":0,"format":"GGUF","validationNote":"legacy"}
        """
        let model = try JSONDecoder().decode(LocalModel.self, from: Data(old.utf8))
        XCTAssertNil(model.kind)
        XCTAssertNil(model.architectureSource)
        XCTAssertNil(model.identificationVersion)
    }

    func testAdapterCannotBeSelectedAsStandaloneChatModel() {
        let adapter = LocalModel(id: UUID(), name: "adapter.gguf", byteCount: 1, importedAt: .now,
            format: .gguf, architecture: "llama", quantization: nil, adapter: "LoRA",
            validationNote: "metadata", kind: .lora)
        XCTAssertFalse(adapter.supportsTextGeneration)
        XCTAssertFalse(adapter.supportsImageGeneration)
    }


    func testBaseModelMetadataDoesNotHideComponents() {
        let metadata = ["modelspec.architecture": "stable-diffusion-xl-v1-base"]
        let vae = ModelIdentity.identify(metadata: metadata, tensors: ["encoder.conv_in.weight": [4], "decoder.conv_out.weight": [4]])
        XCTAssertEqual(vae.kind, .vae)
        XCTAssertEqual(vae.architecture, "sdxl_base_v0.9")
        let clip = ModelIdentity.identify(metadata: metadata, tensors: ["text_model.encoder.layers.0.self_attn.q_proj.weight": [16, 16]])
        XCTAssertEqual(clip.kind, .textEncoder)
        XCTAssertEqual(ModelIdentity.kind(for: "stable-diffusion-v1/vae"), .vae)
        XCTAssertEqual(ModelIdentity.kind(for: "clip-vision"), .visionEncoder)
    }

    func testUnknownOrConflictingMetadataDoesNotHideTensorArchitecture() {
        for declaration in ["custom", "stable-diffusion-v2"] {
            let result = ModelIdentity.identify(metadata: ["architecture": declaration], tensors: ["unet.down_blocks.1.attentions.0.transformer_blocks.0.attn2.to_k.weight": [16, 768]])
            XCTAssertEqual(result.architecture, "v1")
            XCTAssertEqual(result.kind, .image)
        }
    }

    func testFullCheckpointIsNotClassifiedAsItsEmbeddedEncoder() {
        let result = ModelIdentity.identify(metadata: [:], tensors: [
            "model.diffusion_model.input_blocks.0.0.weight": [16, 4, 3, 3],
            "cond_stage_model.transformer.text_model.encoder.layers.0.self_attn.q_proj.weight": [16, 16]
        ])
        XCTAssertEqual(result.kind, .image)
        XCTAssertNil(result.architecture)
    }

    func testMetadataAliasesMatchImporterVersions() {
        for (declared, expected) in [("sd_v1", "v1"), ("stable-diffusion-xl-v1-base", "sdxl_base_v0.9"),
                                      ("sdxl_refiner_v1.0", "sdxl_refiner_v0.9"), ("FLUX.1-dev", "flux1"),
                                      ("FLUX.2-klein-4B", "flux2_4b"), ("QwenImage", "qwen_image")] {
            XCTAssertEqual(ModelIdentity.canonicalArchitecture(declared), expected)
        }
    }

    func testGGUFImageAndEncoderAreNotChatModels() throws {
        for (architecture, kind) in [("flux", ModelKind.image), ("qwen_image", .image), ("t5encoder", .textEncoder), ("unknown", .unknown), ("llama", .text)] {
            let inspection = try inspectGGUF(architecture: architecture)
            XCTAssertEqual(inspection.kind, kind)
            let model = LocalModel(id: UUID(), name: "model.gguf", byteCount: 1, importedAt: .now,
                format: .gguf, architecture: architecture, quantization: nil, adapter: nil,
                validationNote: "metadata", kind: inspection.kind)
            XCTAssertEqual(model.supportsTextGeneration, kind == .text || kind == .unknown)
            XCTAssertEqual(model.needsTextCompatibilityCheck, kind == .unknown)
            XCTAssertFalse(model.supportsImageGeneration)
        }
        XCTAssertEqual(try inspectGGUF(architecture: "clip", vision: true).kind, .visionEncoder)
    }

    func testUnlistedGGUFArchitecturesCanBeValidatedByTheBackend() throws {
        for architecture in ["smollm3", "exaone", "cohere2", "jais", "nemotron"] {
            let inspection = try inspectGGUF(architecture: architecture)
            XCTAssertEqual(inspection.kind, .unknown)
            XCTAssertEqual(inspection.architecture, architecture)
            let model = LocalModel(id: UUID(), name: "model.gguf", byteCount: 1, importedAt: .now,
                format: .gguf, architecture: architecture, quantization: nil, adapter: nil,
                validationNote: inspection.note, kind: inspection.kind)
            XCTAssertTrue(model.supportsTextGeneration)
            XCTAssertTrue(model.needsTextCompatibilityCheck)
        }
    }

    private func inspectGGUF(architecture: String, vision: Bool = false) throws -> ModelInspection {
        var data = Data("GGUF".utf8)
        func number(_ value: UInt64, _ bytes: Int) { for offset in 0..<bytes { data.append(UInt8((value >> (offset * 8)) & 255)) } }
        func string(_ value: String) { number(UInt64(value.utf8.count), 8); data.append(Data(value.utf8)) }
        number(3, 4)
        number(0, 8)
        number(vision ? 2 : 1, 8)
        string("general.architecture"); number(8, 4); string(architecture)
        if vision { string("clip.has_vision_encoder"); number(7, 4); number(1, 1) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        return try ModelFile.inspect(url, name: "model.gguf")
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
