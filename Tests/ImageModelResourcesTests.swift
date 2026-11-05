import XCTest
import ModelZoo
import SQLite3
@testable import LocalAIStudio

final class ImageModelResourcesTests: XCTestCase {
    func testComponentsIncludeDefaultVAEAndEncoderAndReplaceOnlyMatchingFiles() {
        var spec = ModelZoo.Specification(name: "Example", file: "example.ckpt", prefix: "", version: .v1)
        XCTAssertEqual(ImageModelResources.components(for: spec).map(\.file),
                       ["vae_ft_mse_840000_f16.ckpt", "clip_vit_l14_f16.ckpt"])
        ImageModelResources.replacingComponent("vae_ft_mse_840000_f16.ckpt", with: "studio_custom_vae.ckpt", in: &spec)
        XCTAssertEqual(spec.autoencoder, "studio_custom_vae.ckpt")
        XCTAssertNil(spec.textEncoder)
        XCTAssertEqual(spec.file, "example.ckpt")
    }

    func testUnsafeCompanionFilenamesAreRejected() {
        for filename in ["../other.ckpt", "/tmp/other.ckpt", "folder\\other.ckpt", "bad\0.ckpt", "vae.safetensors"] {
            let spec = ModelZoo.Specification(name: "Example", file: "main.ckpt", prefix: "", version: .v1,
                                              autoencoder: filename)
            XCTAssertThrowsError(try ImageModelResources.validateFilenames(in: spec))
        }
    }

    func testRawCheckpointIsRejectedBeforeOpeningTensorStore() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ckpt")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("PK raw pytorch checkpoint".utf8).write(to: source)
        XCTAssertThrowsError(try ImageModelResources.validateCheckpoint(source))
    }

    func testComponentSelectionRoundTripsWithoutChangingUUID() throws {
        let id = UUID()
        let configuration = ImageModelConfiguration(template: "sd_v1.5_f16.ckpt",
                                                    components: ["vae_ft_mse_840000_f16.ckpt": id])
        let restored = try JSONDecoder().decode(ImageModelConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(restored, configuration)
        XCTAssertEqual(restored.components["vae_ft_mse_840000_f16.ckpt"], id)
    }

    func testCheckpointWithMissingExternalWeightsIsRejectedFromMetadata() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ckpt")
        defer { try? FileManager.default.removeItem(at: source) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &database), SQLITE_OK)
        guard let database else { return XCTFail("Could not create fixture") }
        // NNC marks external data with 0x10000000 in the high half of the tensor type.
        let sql = "CREATE TABLE tensors (name TEXT, type INTEGER); INSERT INTO tensors VALUES ('weight', 1152921504606846976);"
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        sqlite3_close(database)
        XCTAssertEqual(result, SQLITE_OK)
        XCTAssertThrowsError(try ImageModelResources.validateCheckpoint(source)) { error in
            XCTAssertTrue(error.localizedDescription.contains("外部张量"))
        }
    }
}
