import Foundation
import XCTest
@testable import ModelValidation

final class ModelNameTests: XCTestCase {
    func testLegacyNameAndCustomDisplayNameRoundTripIndependently() throws {
        let legacy = """
        {"id":"00000000-0000-0000-0000-000000000001","name":"original.gguf","byteCount":4,"importedAt":0,"format":"GGUF","validationNote":"legacy"}
        """
        var model = try JSONDecoder().decode(LocalModel.self, from: Data(legacy.utf8))
        XCTAssertNil(model.displayName)
        XCTAssertEqual(model.title, "original.gguf")
        model.displayName = "我的聊天模型"
        let restored = try JSONDecoder().decode(LocalModel.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(restored.title, "我的聊天模型")
        XCTAssertEqual(restored.name, "original.gguf")
        XCTAssertEqual(restored.id, model.id)
        XCTAssertEqual(restored.format, model.format)
    }
    func testCustomNameAndComponentConfigurationPersistTogether() throws {
        let component = UUID()
        var model = LocalModel(id: UUID(), name: "original.ckpt", byteCount: 128, importedAt: .now,
            format: .checkpoint, architecture: "v1", quantization: nil, adapter: nil, validationNote: "test")
        model.displayName = "画图模型"
        model.imageConfiguration = ImageModelConfiguration(template: "sd_v1.5_f16.ckpt",
            components: ["vae_ft_mse_840000_f16.ckpt": component])
        let restored = try JSONDecoder().decode(LocalModel.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(restored.imageConfiguration, model.imageConfiguration)
        XCTAssertEqual(restored.title, "画图模型")
        XCTAssertEqual(restored.name, "original.ckpt")
    }

}
