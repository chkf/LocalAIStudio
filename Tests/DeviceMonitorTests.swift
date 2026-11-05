import XCTest
@testable import LocalAIStudio

@MainActor
final class DeviceMonitorTests: XCTestCase {
    func testCPUUsesElapsedTimeAndAllowsMultipleCores() throws {
        let monitor = DeviceMonitor()
        let time = ContinuousClock.now

        XCTAssertNil(monitor.sampleCPU(seconds: 10, at: time))
        let percent = try XCTUnwrap(monitor.sampleCPU(seconds: 15, at: time.advanced(by: .seconds(2))))
        XCTAssertEqual(percent, 250, accuracy: 0.001)
    }

    func testStopResetsCPUBaselineInsteadOfCountingBackgroundTime() throws {
        let monitor = DeviceMonitor()
        let time = ContinuousClock.now
        XCTAssertNil(monitor.sampleCPU(seconds: 10, at: time))
        XCTAssertNotNil(monitor.sampleCPU(seconds: 11, at: time.advanced(by: .seconds(2))))

        monitor.stop()
        XCTAssertNil(monitor.sampleCPU(seconds: 20, at: time.advanced(by: .seconds(120))))
        let percent = try XCTUnwrap(monitor.sampleCPU(seconds: 21, at: time.advanced(by: .seconds(122))))
        XCTAssertEqual(percent, 50, accuracy: 0.001)
    }

    func testMissingCPUReadingRequiresANewBaseline() throws {
        let monitor = DeviceMonitor()
        let time = ContinuousClock.now
        XCTAssertNil(monitor.sampleCPU(seconds: 1, at: time))
        XCTAssertNil(monitor.sampleCPU(seconds: nil, at: time.advanced(by: .seconds(2))))
        XCTAssertNil(monitor.sampleCPU(seconds: 5, at: time.advanced(by: .seconds(4))))
        let percent = try XCTUnwrap(monitor.sampleCPU(seconds: 6, at: time.advanced(by: .seconds(6))))
        XCTAssertEqual(percent, 50, accuracy: 0.001)
    }

    func testSamplingIsIdempotentAndPreservesHistoryOnStop() throws {
        let monitor = DeviceMonitor()
        defer { monitor.stop() }
        monitor.start()
        let first = try XCTUnwrap(monitor.history.first)
        XCTAssertTrue(monitor.isSampling)

        monitor.start()
        XCTAssertEqual(monitor.history.count, 1)
        XCTAssertEqual(monitor.snapshot?.date, first.date)

        monitor.stop()
        monitor.refresh()
        XCTAssertFalse(monitor.isSampling)
        XCTAssertEqual(monitor.history.count, 1)
        XCTAssertEqual(monitor.snapshot?.date, first.date)

        monitor.start()
        XCTAssertEqual(monitor.history.count, 2)
        XCTAssertEqual(monitor.history.first?.date, first.date)
        XCTAssertNotEqual(monitor.history.last?.segment, first.segment)
    }

    func testRestartKeepsLastCPUValueAndTimestampWithoutInventingAChartPoint() throws {
        let monitor = DeviceMonitor()
        defer { monitor.stop() }
        monitor.start()
        monitor.refresh()
        let last = try XCTUnwrap(monitor.snapshot)
        XCTAssertNotNil(last.cpuPercent)
        XCTAssertNotNil(last.cpuDate)

        monitor.stop()
        XCTAssertEqual(monitor.snapshot?.cpuPercent, last.cpuPercent)
        monitor.start()

        XCTAssertEqual(monitor.snapshot?.cpuPercent, last.cpuPercent)
        XCTAssertEqual(monitor.snapshot?.cpuDate, last.cpuDate)
        XCTAssertNil(monitor.history.last?.cpuPercent)
    }

    func testHistoryKeepsOnlyTheLastFiveMinutes() throws {
        let monitor = DeviceMonitor()
        let start = Date(timeIntervalSince1970: 0)
        for index in 0..<160 {
            monitor.appendSample(date: start.addingTimeInterval(Double(index * 2)), appMemory: 100, cpuPercent: 20)
        }

        XCTAssertEqual(monitor.history.count, 151)
        XCTAssertEqual(monitor.history.first?.date, start.addingTimeInterval(18))
        XCTAssertEqual(monitor.history.last?.date, start.addingTimeInterval(318))

        monitor.appendSample(date: start.addingTimeInterval(1_000), appMemory: 200, cpuPercent: nil)
        XCTAssertEqual(monitor.history.count, 1)
        XCTAssertEqual(monitor.history.first?.appMemory, 200)
    }

    func testHistoryIsBoundedDuringFrequentRestarts() {
        let monitor = DeviceMonitor()
        let start = Date(timeIntervalSince1970: 0)
        for index in 0..<200 {
            monitor.appendSample(date: start.addingTimeInterval(Double(index) / 10), appMemory: 100, cpuPercent: nil)
        }
        XCTAssertEqual(monitor.history.count, 151)
    }

    func testMissingReadingsBreakChartSegments() {
        let monitor = DeviceMonitor()
        let start = Date(timeIntervalSince1970: 0)
        monitor.appendSample(date: start, appMemory: 100, cpuPercent: 50)
        monitor.appendSample(date: start.addingTimeInterval(2), appMemory: 110, cpuPercent: nil)
        monitor.appendSample(date: start.addingTimeInterval(4), appMemory: 120, cpuPercent: 60)
        monitor.appendSample(date: start.addingTimeInterval(6), appMemory: nil, cpuPercent: 55)
        monitor.appendSample(date: start.addingTimeInterval(8), appMemory: 130, cpuPercent: 40)

        let samples = monitor.history
        XCTAssertNil(samples[1].cpuPercent)
        XCTAssertNil(samples[3].appMemory)
        XCTAssertNotEqual(samples[0].segment, samples[2].segment)
        XCTAssertNotEqual(samples[2].segment, samples[4].segment)
        XCTAssertEqual(samples[1].segment, samples[2].segment)
        XCTAssertEqual(samples[3].segment, samples[4].segment)
    }
}
