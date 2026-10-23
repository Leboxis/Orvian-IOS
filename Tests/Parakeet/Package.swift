// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "UltraSmoke", platforms: [.macOS(.v14)], dependencies: [
    .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "503b4bd1bbf7220882de39fe8ae6716aae4132da", traits: [])
], targets: [.executableTarget(name: "UltraSmoke", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")], path: "Sources")])
