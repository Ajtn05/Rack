import Foundation

/// A dependency-free assertion harness.
///
/// Neither `XCTest` nor `Testing` is present in a Command Line Tools–only
/// toolchain — both ship inside Xcode — so `swift test` cannot run here. Rather
/// than make a full Xcode install a prerequisite for verifying the DSP, the
/// suite is an ordinary executable:
///
///     swift run RackTests
///
/// If Xcode is installed later, this file is the only thing that has to go: the
/// test bodies map onto XCTest one-for-one.
enum Check {
    nonisolated(unsafe) private static var failures: [String] = []
    nonisolated(unsafe) private static var checks = 0
    nonisolated(unsafe) private static var currentSuite = ""

    static func suite(_ name: String, _ body: () -> Void) {
        currentSuite = name
        print("• \(name)")
        body()
    }

    static func isTrue(
        _ condition: Bool,
        _ what: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        checks += 1
        guard !condition else { return }
        record("\(what) — expected true", file: file, line: line)
    }

    static func equal<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ what: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        checks += 1
        guard actual != expected else { return }
        record("\(what) — got \(actual), expected \(expected)", file: file, line: line)
    }

    /// The workhorse for DSP: compares within an absolute tolerance, which is
    /// what a frequency-response assertion actually needs.
    static func close(
        _ actual: Double,
        _ expected: Double,
        tolerance: Double,
        _ what: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        checks += 1
        let delta = abs(actual - expected)
        guard delta > tolerance || actual.isNaN else { return }
        record(
            String(
                format: "%@ — got %.6f, expected %.6f ±%.6f (off by %.6f)",
                what, actual, expected, tolerance, delta
            ),
            file: file, line: line
        )
    }

    private static func record(_ message: String, file: StaticString, line: UInt) {
        let location = URL(fileURLWithPath: "\(file)").lastPathComponent
        let entry = "\(currentSuite): \(message)  [\(location):\(line)]"
        failures.append(entry)
        print("  ✗ \(entry)")
    }

    /// Prints the tally and exits non-zero if anything failed, so the suite is
    /// usable from a build script or CI without any harness around it.
    static func finish() -> Never {
        print("")
        if failures.isEmpty {
            print("✓ \(checks) checks passed")
            exit(0)
        }
        print("✗ \(failures.count) of \(checks) checks failed")
        exit(1)
    }
}
