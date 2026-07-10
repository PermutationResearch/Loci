// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Loci",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Loci", targets: ["Loci"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Loci",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("WebKit"),
                .linkedFramework("PDFKit"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Accelerate"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "LociTests",
            dependencies: [
                "Loci",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        )
    ]
)
