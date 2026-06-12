import Foundation

func describeError(_ error: Error) -> String {
    if let localized = (error as? LocalizedError)?.errorDescription {
        return localized
    }
    return String(describing: error)
}
