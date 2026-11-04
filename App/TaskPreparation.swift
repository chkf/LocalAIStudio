import Foundation
import Observation

/// A pending chat/image start owns this token while the previous runtime is stopping.
@MainActor @Observable
final class TaskPreparation {
    private(set) var id: UUID?
    private(set) var title = ""
    var isPreparing: Bool { id != nil }

    func begin(_ title: String) -> UUID? {
        guard id == nil else { return nil }
        let request = UUID()
        id = request
        self.title = title
        return request
    }

    func isCurrent(_ request: UUID) -> Bool { id == request }

    func finish(_ request: UUID) {
        guard id == request else { return }
        cancel()
    }

    func cancel() {
        id = nil
        title = ""
    }
}
