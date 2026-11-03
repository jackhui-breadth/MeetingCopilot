// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MeetingCopilot",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MeetingCopilot", targets: ["MeetingCopilot"])
    ],
    targets: [
        .target(
            name: "AudioSupport",
            path: "Sources/AudioSupport",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "MeetingCopilot",
            dependencies: ["AudioSupport"],
            path: "MeetingCopilot",
            exclude: [
                "Info.plist"
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "MeetingCopilotTests",
            dependencies: ["MeetingCopilot"],
            path: "Tests/MeetingCopilotTests"
        )
    ]
)
