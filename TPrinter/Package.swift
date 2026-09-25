// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TPrinter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TPrinter", targets: ["TPrinter"])
    ],
    targets: [
        .executableTarget(
            name: "TPrinter",
            path: "Sources/TPrinter",
            linkerSettings: [
                // Embed Info.plist so the Bluetooth usage description exists even for `swift run`.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Support/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "TPrinterTests",
            dependencies: ["TPrinter"],
            path: "Tests/TPrinterTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
