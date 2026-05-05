// swift/swiftcap/Package.swift
// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "swiftcap",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "swiftcap", targets: ["Swiftcap"])
    ],
    targets: [
        .executableTarget(
            name: "Swiftcap",
            path: "Sources/Swiftcap",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Swiftcap/Info.plist"
                ], .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(name: "SwiftcapTests", dependencies: ["Swiftcap"], path: "Tests/SwiftcapTests")
    ]
)
