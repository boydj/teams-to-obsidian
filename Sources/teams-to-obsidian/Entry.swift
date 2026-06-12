import TeamsToObsidianKit

// Note: this file must not be named main.swift, or the @main attribute
// would conflict with the implicit top-level entry point.
@main
struct Entry {
    static func main() async {
        await TeamsToObsidianCLI.run()
    }
}
