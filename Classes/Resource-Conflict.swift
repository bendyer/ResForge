import Foundation
import RKSupport

// Extend the Resource class to add conflict checking when changing the type or id
extension Resource {
    func canSetType(_ type: String) -> Bool {
        return type == self.type || !self.hasConflict(type: type, id: self.id)
    }
    
    func canSetID(_ id: Int) -> Bool {
        return id == self.id || !self.hasConflict(type: self.type, id: id)
    }
    
    private func hasConflict(type: String, id: Int) -> Bool {
        // If changing id or type we need to check whether a matching resource already exists
        if (document as? ResourceDocument)?.collection.findResource(type: type, id: id) != nil {
            document?.presentError(ResourceError.conflict(type, id))
            return true
        }
        return false
    }
}

enum ResourceError: LocalizedError {
    case conflict(String, Int)
    var errorDescription: String? {
        switch self {
        case .conflict(let type, let id):
            return String(format: NSLocalizedString("A resource of type '%@' with ID %ld already exists.", comment: ""), type, id)
        }
    }
    var recoverySuggestion: String? {
        switch self {
        case .conflict(_, _):
            return String(format: NSLocalizedString("Please enter a unique value.", comment: ""))
        }
    }
}
