// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GarminDesk",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "GarminDesk", targets: ["GarminDesk"])],
    targets: [.executableTarget(name: "GarminDesk", path: "Sources", exclude: ["GarminDeskWidgets"], sources: ["GarminDesk", "Shared"])]
)
