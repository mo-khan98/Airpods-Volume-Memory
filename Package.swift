// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirpodVolumeMacApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AirpodVolumeMacApp", targets: ["AirpodVolumeMacApp"])
    ],
    targets: [
        .executableTarget(
            name: "AirpodVolumeMacApp",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
