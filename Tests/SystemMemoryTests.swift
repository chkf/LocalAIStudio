import XCTest
@testable import LocalAIStudio

final class SystemMemoryTests: XCTestCase {
    func testUsedIsTheComplementOfFreeRatherThanAppBudget() {
        let memory = SystemMemory(total: 12_000, free: 5_000, active: 1_000, inactive: 2_000, wired: 3_000, compressed: 1_000)
        XCTAssertEqual(memory.used, 7_000)
        XCTAssertEqual(memory.usedFraction!, 7.0 / 12.0, accuracy: 0.0001)
    }

    func testEmptyTotalDoesNotProduceAnInvalidGauge() {
        let memory = SystemMemory(total: 0, free: 0, active: 0, inactive: 0, wired: 0, compressed: 0)
        XCTAssertEqual(memory.used, 0)
        XCTAssertNil(memory.usedFraction)
    }

    func testFreeAboveTotalDoesNotUnderflow() {
        let memory = SystemMemory(total: 10, free: 11, active: 0, inactive: 0, wired: 0, compressed: 0)
        XCTAssertEqual(memory.used, 0)
        XCTAssertEqual(memory.usedFraction, 0)
    }

    func testKernelReadingWhenAvailable() throws {
        guard let memory = SystemMemory.read() else {
            throw XCTSkip("System-wide VM statistics unavailable on this host; UI must show an unavailable reading.")
        }
        XCTAssertGreaterThan(memory.total, 0)
        XCTAssertLessThanOrEqual(memory.free, memory.total)
        XCTAssertTrue((0...1).contains(try XCTUnwrap(memory.usedFraction)))
    }
}
