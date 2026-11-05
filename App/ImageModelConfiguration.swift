import Foundation

struct ImageModelConfiguration: Codable, Sendable, Equatable {
    var template: String? = nil
    /// Required companion filename to the imported model selected by the user.
    var components: [String: UUID] = [:]
}
