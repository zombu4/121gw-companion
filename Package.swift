// swift-tools-version:5.9
// Meter121Kit: the 121GW protocol of the open firmware (frames, link 2, display decoding, keys, clock, page Ld
// transfers), with no dependency on CoreBluetooth or SwiftUI, so it builds and is tested on macOS, iOS and Linux.
// The iPhone app (App/) uses it as a local package.
import PackageDescription

let package = Package(
    name: "Meter121Kit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Meter121Kit", targets: ["Meter121Kit"]),
    ],
    targets: [
        .target(name: "Meter121Kit", path: "Sources/Meter121Kit"),
        .testTarget(name: "Meter121KitTests", dependencies: ["Meter121Kit"], path: "Tests/Meter121KitTests"),
    ]
)
