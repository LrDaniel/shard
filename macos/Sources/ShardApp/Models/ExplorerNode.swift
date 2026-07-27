import Foundation

struct ExplorerNode: Identifiable, Hashable {
    enum Kind: Hashable {
        case connection
        case database
        case collection
        case category
    }

    let id: String
    let name: String
    let kind: Kind
    var children: [ExplorerNode]?

    var systemImage: String {
        switch kind {
        case .connection: return "server.rack"
        case .database: return "cylinder"
        case .collection: return "tablecells"
        case .category: return "folder"
        }
    }
}
