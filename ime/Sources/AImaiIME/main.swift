import Cocoa
import InputMethodKit

// 入力メソッドのエントリーポイント。
// IMKServer を立ち上げ、変換エンジン（モデル）の読み込みを裏で始めてから run loop に入る。

guard let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String else {
    fatalError("Info.plist に InputMethodConnectionName がありません")
}

let server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier)
EngineHolder.shared.preload()

withExtendedLifetime(server) {
    NSApplication.shared.run()
}
