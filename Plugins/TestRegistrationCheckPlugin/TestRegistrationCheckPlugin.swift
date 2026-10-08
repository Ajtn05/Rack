import Foundation
import PackagePlugin

/// Runs `Scripts/check-test-registration.sh` before every build of
/// `RackTests`, the same way `BoundaryCheckPlugin` runs the import-boundary
/// check before every build of `App`: a prebuild command, not cached against
/// an input list, so it never gets skipped because SwiftPM decided nothing
/// changed.
@main
struct TestRegistrationCheckPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let root = context.package.directoryURL
        let script = root.appending(path: "Scripts/check-test-registration.sh")

        return [
            .prebuildCommand(
                displayName: "Checking test registration",
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [script.path(percentEncoded: false), root.path(percentEncoded: false)],
                outputFilesDirectory: context.pluginWorkDirectoryURL
            )
        ]
    }
}
