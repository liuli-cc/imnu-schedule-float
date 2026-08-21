// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IMNUScheduleFloat",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "IMNUScheduleFloat", targets: ["IMNUScheduleFloat"])],
    targets: [
        .executableTarget(
            name: "IMNUScheduleFloat",
            path: "Sources/IMNUScheduleFloat"
        )
    ]
)
