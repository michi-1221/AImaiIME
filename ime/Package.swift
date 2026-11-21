// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AImaiIME",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AImaiIME", targets: ["AImaiIME"]),
        .executable(name: "aime-cli", targets: ["aime-cli"]),
    ],
    targets: [
        // llama.cpp の公式ビルド済み XCFramework（scripts/fetch-deps.sh で取得、バージョン固定）
        .binaryTarget(name: "llama", path: "vendor/llama.xcframework"),

        // 変換ロジック（llama.cpp に依存しない部分）。ユニットテストはここを対象にする。
        .target(name: "AIMECore"),

        // llama.cpp + Metal による TextGenerator 実装
        .target(name: "AIMELlama", dependencies: ["AIMECore", "llama"]),

        // 入力メソッド本体（InputMethodKit）。scripts/build.sh で .app にまとめる。
        .executableTarget(
            name: "AImaiIME",
            dependencies: ["AIMECore", "AIMELlama"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("InputMethodKit"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),

        // 実推論の確認とレイテンシ測定用の CLI
        .executableTarget(name: "aime-cli", dependencies: ["AIMECore", "AIMELlama"]),

        .testTarget(name: "AIMECoreTests", dependencies: ["AIMECore"]),
        .testTarget(name: "AIMELlamaTests", dependencies: ["AIMECore", "AIMELlama"]),
    ]
)
