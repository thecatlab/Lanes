// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lanes",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Lanes", targets: ["Lanes"]), .executable(name: "LanesProxy", targets: ["LanesProxy"])],
    targets: [
        .target(name: "LanesCore"),
        .target(name: "LanesProxyKit", dependencies: ["LanesCore"]),
        .executableTarget(name: "LanesProxy", dependencies: ["LanesProxyKit"]),
        .executableTarget(name: "Lanes", dependencies: ["LanesCore", "LanesProxyKit"])
    ],
    swiftLanguageModes: [.v5]
)
