import Foundation
import SystemPackage
import WAT
import WasmKit

@available(macOS 11, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
public func spectest(
    path: [String],
    include: String?,
    exclude: String?,
    verbose: Bool = false,
    parallel: Bool = true
) async throws -> Bool {
    let printVerbose = verbose
    @Sendable func log(_ message: String, verbose: Bool = false) {
        if !verbose || printVerbose {
            fputs(message + "\n", stderr)
        }
    }
    @Sendable func log(_ message: String, path: String, location: Location, verbose: Bool = false) {
        if !verbose || printVerbose {
            let (line, _) = location.computeLineAndColumn()
            fputs("\(path):\(line): " + message + "\n", stderr)
        }
    }
    func percentage(_ numerator: Int, _ denominator: Int) -> String {
        "\(Int(Double(numerator) / Double(denominator) * 100))%"
    }

    let include = include.flatMap { $0.split(separator: ",").map(String.init) } ?? []
    let exclude = exclude.flatMap { $0.split(separator: ",").map(String.init) } ?? []

    let testCases: [TestCase]
    do {
        testCases = try TestCase.load(include: include, exclude: exclude, in: path, log: { log($0) })
    } catch {
        fatalError("failed to load test: \(error)")
    }

    guard !testCases.isEmpty else {
        log("No test found")
        return true
    }

    // https://github.com/WebAssembly/spec/tree/8a352708cffeb71206ca49a0f743bdc57269fb1a/interpreter#spectest-host-module
    let hostModule = try parseWasm(
        bytes: wat2wasm(
            """
                (module
                  (global (export "global_i32") i32 (i32.const 666))
                  (global (export "global_i64") i64 (i64.const 666))
                  (global (export "global_f32") f32 (f32.const 666.6))
                  (global (export "global_f64") f64 (f64.const 666.6))

                  (table (export "table") 10 20 funcref)
                  (table (export "table64") 10 20 funcref)

                  (memory (export "memory") 1 2)

                  (func (export "print"))
                  (func (export "print_i32") (param i32))
                  (func (export "print_i64") (param i64))
                  (func (export "print_f32") (param f32))
                  (func (export "print_f64") (param f64))
                  (func (export "print_i32_f32") (param i32 f32))
                  (func (export "print_f64_f64") (param f64 f64))
                )
            """))

    @Sendable func runTestCase(testCase: TestCase) throws -> [Result] {
        var testCaseResults = [Result]()
        let logDuration: () -> Void
        if #available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *) {
            let start = ContinuousClock.now
            logDuration = {
                let elapsed = ContinuousClock.now - start
                log("Finished \(testCase.path) in \(elapsed)")
            }
        } else {
            // Fallback on earlier versions
            logDuration = {}
        }
        log("Testing \(testCase.path)")
        try testCase.run(spectestModule: hostModule) { testCase, location, result in
            switch result {
            case let .failed(reason):
                log("\(result.banner) \(reason)", path: testCase.path, location: location)
            case let .skipped(reason):
                log("\(result.banner) \(reason)", path: testCase.path, location: location, verbose: true)
            case .passed:
                log(result.banner, path: testCase.path, location: location, verbose: true)
            default:
                log(result.banner, path: testCase.path, location: location)
            }
            testCaseResults.append(result)
        }

        logDuration()

        return testCaseResults
    }

    let results: [Result]

    if parallel {
        results = try await withThrowingTaskGroup(of: [Result].self) { group in
            for testCase in testCases {
                group.addTask {
                    try await Task { try runTestCase(testCase: testCase) }.value
                }
            }

            var results = [Result]()
            for try await testCaseResults in group {
                results.append(contentsOf: testCaseResults)
            }

            return results
        }
    } else {
        results = try testCases.flatMap { try runTestCase(testCase: $0) }
    }

    let passingCount = results.filter { if case .passed = $0 { return true } else { return false } }.count
    let skippedCount = results.filter { if case .skipped = $0 { return true } else { return false } }.count
    let failedCount = results.filter { if case .failed = $0 { return true } else { return false } }.count

    print(
        """
        \(passingCount)/\(results.count) (\(
            percentage(passingCount, results.count)
        ) passing, \(
            percentage(skippedCount, results.count)
        ) skipped, \(
            percentage(failedCount, results.count)
        ) failed)
        """
    )
    return failedCount == 0
}
