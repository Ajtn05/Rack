import Foundation
import PackagePlugin

/// Runs `Scripts/check-boundaries.sh` before every build of the target it is
/// attached to (the `App` executable, which pulls in every other target).
///
/// A prebuild command runs on each build rather than being cached against an
/// input list, which is what we want: the check is cheap and must never be
/// skipped because SwiftPM decided nothing changed.
@main
struct BoundaryCheckPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let root = context.package.directoryURL
        let script = root.appending(path: "Scripts/check-boundaries.sh")

        return [
            .prebuildCommand(
                displayName: "Checking module boundaries",
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [script.path(percentEncoded: false), root.path(percentEncoded: false)],
                outputFilesDirectory: context.pluginWorkDirectoryURL
            )
        ]
    }
}
