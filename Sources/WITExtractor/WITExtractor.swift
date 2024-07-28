import Foundation

@available(iOS, unavailable)
@available(watchOS, unavailable)
@available(tvOS, unavailable)
@available(visionOS, unavailable)
public struct WITExtractor {
    public struct Output {
        public var witContents: String
        public var interfaceName: String
        public var sourceSummary: SwiftSourceSummary
        public var typeMapping: (_ witName: String) -> String?
    }

    let namespace: String
    let packageName: String
    let digester: SwiftAPIDigester
    let extraDigesterArguments: [String]
    let diagnosticCollection = DiagnosticCollection()

    public var diagnostics: [Diagnostic] {
        diagnosticCollection.diagnostics
    }

    public init(
        namespace: String,
        packageName: String,
        digesterPath: String,
        extraDigesterArguments: [String]
    ) {
        self.namespace = namespace
        self.packageName = packageName
        self.digester = SwiftAPIDigester(executableURL: URL(fileURLWithPath: digesterPath))
        self.extraDigesterArguments = extraDigesterArguments
    }

    public func run(moduleName: String) throws -> Output {
        guard #available(macOS 11, iOS 14.0, watchOS 7.0, tvOS 14.0, *) else {
            fatalError("WITExtractor requires macOS 11+")
        }
        let header = """
            // DO NOT EDIT.
            //
            // Generated by the WITExtractor

            """
        var output = try runWithoutHeader(moduleName: moduleName)
        output.witContents = header + output.witContents
        return output
    }

    @available(macOS 11, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
    func runWithoutHeader(moduleName: String) throws -> Output {
        let output = try digester.dumpSDK(moduleName: moduleName, arguments: extraDigesterArguments)
        var typeMapping = TypeMapping()
        typeMapping.collect(digest: output)

        var summaryBuilder = SourceSummaryBuilder(diagnostics: diagnosticCollection, typeMapping: typeMapping)
        summaryBuilder.build(digest: output)

        var translation = ModuleTranslation(
            diagnostics: diagnosticCollection,
            typeMapping: typeMapping,
            builder: WITBuilder(
                interfaceName: ConvertCase.witIdentifier(identifier: [moduleName])
            )
        )
        translation.translate(sourceSummary: summaryBuilder.sourceSummary)

        let printer = SourcePrinter(
            header: """
                package \(ConvertCase.witIdentifier(identifier: namespace)):\(ConvertCase.witIdentifier(identifier: packageName))

                """
        )
        translation.builder.print(printer: printer)
        return Output(
            witContents: printer.contents,
            interfaceName: translation.builder.interfaceName,
            sourceSummary: summaryBuilder.sourceSummary,
            typeMapping: typeMapping.qualifiedName(byWITName:)
        )
    }
}
