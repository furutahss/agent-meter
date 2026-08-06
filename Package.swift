// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentMeterSpike",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentMeterCore", targets: ["AgentMeterCore"]),
        .executable(name: "agent-meter-spike", targets: ["AgentMeterSpike"]),
    ],
    targets: [
        .target(name: "AgentMeterCore"),
        .executableTarget(name: "AgentMeterSpike", dependencies: ["AgentMeterCore"]),
        .testTarget(name: "AgentMeterCoreTests", dependencies: ["AgentMeterCore"], resources: [.process("Fixtures")]),
    ]
)
