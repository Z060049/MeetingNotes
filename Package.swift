// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MeetingNotes",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MeetingNotes", targets: ["MeetingNotesApp"]),
        .library(name: "MeetingNotesCore", targets: ["MeetingNotesCore"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "MeetingNotesCore",
            dependencies: [],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "MeetingNotesApp",
            dependencies: ["MeetingNotesCore"]
        ),
        .testTarget(
            name: "MeetingNotesCoreTests",
            dependencies: ["MeetingNotesCore"]
        )
    ]
)
