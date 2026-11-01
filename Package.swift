// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TrainAlarm",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // Data sources (České dráhy IPWS, IDOS) and the ride model. No UI.
        .target(name: "TrainAlarmKit"),
        // Menu bar app.
        .executableTarget(
            name: "TrainAlarm",
            dependencies: ["TrainAlarmKit"]
        ),
        .testTarget(
            name: "TrainAlarmKitTests",
            dependencies: ["TrainAlarmKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
