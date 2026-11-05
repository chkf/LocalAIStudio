import XCTest
@testable import LocalAIStudio

final class SystemMemoryTests: XCTestCase {
    private func sample(total: UInt64 = 12_000, free: UInt64 = 200,
                        inactive: UInt64 = 6_000, anonymous: UInt64 = 4_000,
                        purgeable: UInt64 = 1_000) -> SystemMemory {
        SystemMemory(total: total, free: free, active: 2_000, inactive: inactive,
                     wired: 2_000, compressed: 500, anonymous: anonymous,
                     purgeable: purgeable, fileBacked: 5_000)
    }

    func testCacheDoesNotMakeTheDashboardLookFull() {
        let memory = sample()
        XCTAssertEqual(memory.occupied, 11_800)
        XCTAssertEqual(memory.used, 5_500)
        XCTAssertEqual(memory.usedFraction!, 5.5 / 12.0, accuracy: 0.0001)
        XCTAssertEqual(memory.fileBacked, 5_000)
        XCTAssertEqual(memory.free, 200)
    }

    func testInactiveMemoryIsNotBlindlySubtractedAsAvailable() {
        XCTAssertEqual(sample(inactive: 0).used, sample(inactive: 6_000).used)
    }

    func testPurgeableCounterDoesNotUnderflowAnonymousMemory() {
        XCTAssertEqual(sample(anonymous: 500, purgeable: 1_000).used, 2_500)
    }

    func testEmptyTotalDoesNotProduceAnInvalidGauge() {
        XCTAssertEqual(sample(total: 0).used, 0)
        XCTAssertNil(sample(total: 0).usedFraction)
    }

    func testSnapshotBounds() {
        XCTAssertEqual(sample(total: 10, free: 11).occupied, 0)
        XCTAssertEqual(sample(total: 10).usedFraction, 1)
    }

    func testKernelReadingWhenAvailable() throws {
        guard let memory = SystemMemory.read() else {
            throw XCTSkip("System-wide VM statistics unavailable on this host; UI must show an unavailable reading.")
        }
        XCTAssertGreaterThan(memory.total, 0)
        XCTAssertTrue((0...1).contains(try XCTUnwrap(memory.usedFraction)))
    }
}
