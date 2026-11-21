import Foundation

/// 直接モード（`inputMode = direct`）の中で、入力欄ごとに使う方式。
public enum FieldMethod: Equatable {
    /// 打鍵はすぐ確定し、変換キーでカーソル直前のローマ字列を後から置き換える。
    case replace
    /// 置き換えに対応していない入力欄（ターミナルなど）: ローマ字を未確定文字として持ち、変換キーで変換して差し替える。
    case marked
}

/// クライアントが前のテキストを返せるかを、その場で試した結果。
public enum ClientCapability: Equatable {
    /// カーソル直前の1文字を取得できた
    case supported
    /// カーソル位置がわからない、または直前の1文字を取得できなかった
    case unsupported
    /// カーソルが先頭（位置 0）で、試せる文字がない
    case unknown

    /// カーソル直前の1文字を取得してみる。
    /// - Parameters:
    ///   - selectedRange: クライアントの `selectedRange()`（取得できなければ nil）。
    ///   - fetch: 範囲のテキストをクライアントから取る。取れない・要求と違う長さのときは nil。
    public static func probe(selectedRange: NSRange?, fetch: (NSRange) -> String?) -> ClientCapability {
        guard let sel = selectedRange, sel.location != NSNotFound else { return .unsupported }
        if sel.location == 0 { return .unknown }
        return fetch(NSRange(location: sel.location - 1, length: 1)) != nil ? .supported : .unsupported
    }
}

/// 直接モードでの、入力欄（入力コンテキスト）ごとの方式の判定。
///
/// 同じアプリ（たとえば Chrome）の中でも、前のテキストを返す欄と返さない欄があるので、アプリ単位ではなく
/// 入力欄ごとに決める。
///
/// - 試す時点: フォーカスが来たとき（activateServer）と、未確定文字がない状態で文字を打ち始めるたび。
///   Chrome などでは、同じページの中で別の欄に移っても IME には通知が来ないことがあるので、
///   1つの欄で一度決めて覚えるのではなく、打ち始めるたびに今の欄を試す。
/// - 取得できれば置き換え、できなければ未確定文字。
/// - 試せない（カーソルが先頭にいる）ときは未確定文字（どのクライアントでもテキストを壊さないので、わからないときはこちら）。
/// - 置き換えで変換キーを押したのに前のテキストが取れなかった、または置き換えた結果を確かめられなかったときは、
///   試した結果にかかわらず未確定文字に固定する。固定は、入力欄が変わった合図（フォーカスが来た・クリック）で解く。
public struct FieldModeState: Equatable {
    /// 直前に決めた方式（nil はまだ試していない）
    public private(set) var lastMethod: FieldMethod?
    /// 置き換えで失敗して、未確定文字に固定したか
    public private(set) var lockedToMarked = false

    public init() {}

    /// 新しい入力欄になった（フォーカスが来た・クリックした）。
    /// - Parameter lockedToMarked: 最初から未確定文字に固定するか（そのアプリで前に失敗していたとき。`AppModeMemory`）。
    public mutating func reset(lockedToMarked: Bool = false) {
        lastMethod = lockedToMarked ? .marked : nil
        self.lockedToMarked = lockedToMarked
    }

    /// 今の方式を決める（固定されていなければ `capability` で試す）。
    public mutating func method(capability: () -> ClientCapability) -> FieldMethod {
        let method: FieldMethod
        if lockedToMarked {
            method = .marked
        } else {
            method = capability() == .supported ? .replace : .marked
        }
        lastMethod = method
        return method
    }

    /// 置き換えで前のテキストが取れなかった・置き換えを確かめられなかった。入力欄が変わるまで未確定文字にする。
    public mutating func markUnsupported() {
        lockedToMarked = true
        lastMethod = .marked
    }
}

/// 直接モードで、1回の打鍵をどう扱うか。
public enum DirectKeyRoute: Equatable {
    /// 未確定文字の方式で扱う（`MarkedComposer` に渡す）
    case marked
    /// 置き換えの変換キーとして扱う（変換・候補送り。できなければキーを通す）
    case convert
    /// アプリにそのまま通す（打鍵バッファには記録する）
    case passThrough

    /// - Parameters:
    ///   - composerIsEmpty: 未確定文字がないか。
    ///   - method: 今の入力欄の方式を試す（必要なときだけ呼ぶ）。
    public static func route(_ key: KeyStroke, convertKey: ConvertKey, composerIsEmpty: Bool,
                             method: () -> FieldMethod) -> DirectKeyRoute {
        // 未確定文字がある間は、すべてのキーを未確定文字の方式で扱う（変換キーも必ず IME が受け取る）
        if !composerIsEmpty { return .marked }
        // 未確定文字がない状態で文字を打ち始めたら、今の入力欄の方式を試す
        if case .char = ComposerKey.classify(key, convertKey: convertKey) {
            return method() == .marked ? .marked : .passThrough
        }
        // 変換キー（置き換えに対応していない入力欄では、未確定文字がないときの変換キーはそのまま通す）
        if convertKey.matches(key) {
            return method() == .replace ? .convert : .passThrough
        }
        // それ以外（変換キーが Tab 以外のときの Tab を含む）はそのまま通す
        return .passThrough
    }
}

/// 置き換え・判定で失敗したアプリ（bundle ID）を、IME のプロセスが動いている間覚えておく。
///
/// 一度でも失敗したアプリは、次にフォーカスが来たときも最初から未確定文字の方式で始める
/// （Orca のように隠し入力欄の中身を返すアプリで、アプリを移るたびに1回空振りしないようにするため）。
/// 安全側（未確定文字）に倒すだけの記憶なので、アプリの中の全欄が未確定文字になってもかまわない。
public struct AppModeMemory: Equatable {
    public private(set) var unsupportedApps: Set<String> = []

    public init() {}

    /// このアプリで失敗した（bundle ID が取れなければ覚えない）。
    public mutating func markUnsupported(bundleID: String?) {
        guard let id = bundleID, !id.isEmpty else { return }
        unsupportedApps.insert(id)
    }

    /// このアプリで、最初から未確定文字の方式で始めるか。
    public func startsMarked(bundleID: String?) -> Bool {
        guard let id = bundleID, !id.isEmpty else { return false }
        return unsupportedApps.contains(id)
    }
}

/// 直接モードで、IME が打鍵バッファに記録した直近の文字と、クライアントが返す「カーソル直前の文字列」を比べる。
///
/// 「直前1文字を取れるか」だけの判定では、Orca（Electron/xterm.js 系）のように画面裏の隠し入力欄の中身を返すアプリを
/// 置き換え可能と誤判定する。打鍵のたびに直近の数文字を比べ、食い違ったら置き換えに対応していないとみなす。
public enum BufferConsistency: Equatable {
    /// 一致した
    case consistent
    /// 食い違った（中身が違う・比べる範囲を取得できない・位置が記録とずれた）: 置き換えに対応していないとみなす
    case mismatch
    /// 比べられない（バッファが空・位置の記録がない・カーソル位置がわからない・範囲選択中）
    case notApplicable

    /// 比べる最大の長さ（UTF-16 単位）
    public static let compareLength = 16
    /// 「照合済み」とみなすのに必要な、一致した長さ（UTF-16 単位）。
    /// 1文字だけだと、隠し入力欄に直近の1文字が残っているアプリでも一致してしまうため、2以上にする。
    public static let minimumVerifiedLength = 2

    /// 比べるバッファの末尾（最大 `compareLength`。サロゲートペアや書記素を割らない）。
    public static func comparedTail(of buffer: TypingBuffer) -> String {
        var tail = ""
        for ch in buffer.text.reversed() {
            if tail.utf16.count + String(ch).utf16.count > compareLength { break }
            tail = String(ch) + tail
        }
        return tail
    }

    /// - Parameters:
    ///   - buffer: 打鍵バッファ（この打鍵を記録する前の状態）。
    ///   - selectedRange: 今のクライアントの `selectedRange()`。
    ///   - fetch: 範囲のテキストをクライアントから取る。取れない・要求と違う長さのときは nil。
    public static func check(buffer: TypingBuffer, selectedRange: NSRange?, fetch: (NSRange) -> String?) -> BufferConsistency {
        guard !buffer.text.isEmpty, let expected = buffer.expectedLocation,
              let sel = selectedRange, sel.location != NSNotFound, sel.length == 0 else {
            return .notApplicable
        }
        // IME が見ていない理由（クリック・矢印・⌘ の操作などは、その時点でバッファを空にしている）で
        // カーソル位置が記録とずれた: 隠し入力欄を返すアプリでは、入力のたびに中身が消えて位置が戻る
        guard sel.location == expected else { return .mismatch }
        let tail = comparedTail(of: buffer)
        let length = tail.utf16.count
        // バッファが記録した位置より長い（`TypingBuffer.set` に食い違った値を渡したときなど）なら比べない
        guard length > 0, length <= sel.location else { return .notApplicable }
        guard let actual = fetch(NSRange(location: sel.location - length, length: length)) else { return .mismatch }
        return Array(actual.utf16) == Array(tail.utf16) ? .consistent : .mismatch
    }
}

/// 直接モードで状態を調べるためのクライアントの抽象（IMK のクライアントや、テスト用の偽物）。
public protocol DirectTextClient {
    /// `selectedRange()`（カーソル位置がわからなければ nil）
    var selectedRange: NSRange? { get }
    /// 範囲のテキスト。取れない・要求と違う長さのときは nil。
    func text(in range: NSRange) -> String?
    /// アプリの bundle ID
    var bundleID: String? { get }
}

/// 直接モードの状態機械: 打鍵バッファ・入力欄の方式・照合・振り分けをまとめて判定する（クライアントに依存しない）。
///
/// 1回の打鍵ごとに `decide` を呼ぶ。
/// 1. 照合: 置き換えの方式で動いている欄なら、打鍵バッファの直近の文字とクライアントのテキストを比べる（`BufferConsistency`）。
///    食い違ったら、その欄とアプリを未確定文字の方式にする。2文字以上一致したら、その欄を「照合済み」にする。
/// 2. 振り分け（`DirectKeyRoute`）。
/// 3. 照合済みでない欄では、置き換え（変換キー）を許さず、変換キーをそのまま通す
///    （フォーカス直後に打鍵せず変換キーを押したとき、隠し入力欄の古い中身を信じて置き換えないため）。
public struct DirectInputState: Equatable {
    public var buffer = TypingBuffer()
    public private(set) var field = FieldModeState()
    /// この入力欄で、照合が一度でも一致したか（2文字以上）。入力欄が変わったら（フォーカス・クリック）false に戻す。
    public private(set) var verified = false

    public init() {}

    /// 新しい入力欄になった（フォーカスが来た・クリック）。そのアプリで前に失敗していたら、最初から未確定文字の方式にする。
    public mutating func startField(bundleID: String?, memory: AppModeMemory) {
        field.reset(lockedToMarked: memory.startsMarked(bundleID: bundleID))
        buffer.reset()
        verified = false
    }

    /// 今の入力欄の方式を試す（フォーカスが来たときなど）。
    @discardableResult
    public mutating func probe(_ client: DirectTextClient) -> FieldMethod {
        field.method { ClientCapability.probe(selectedRange: client.selectedRange, fetch: client.text(in:)) }
    }

    /// この入力欄（とアプリ）を、置き換えに対応していないとして未確定文字の方式にする。
    public mutating func markUnsupported(bundleID: String?, memory: inout AppModeMemory) {
        field.markUnsupported()
        memory.markUnsupported(bundleID: bundleID)
        buffer.reset()
        verified = false
    }

    public enum Decision: Equatable {
        /// 未確定文字の方式で扱う（`MarkedComposer` に渡す）
        case marked
        /// 置き換えの変換キーとして扱う（変換・候補送り。できなければ呼び出し側がキーを通して `record` する）
        case convert
        /// アプリにそのまま通す（呼び出し側が `record` する）
        case passThrough
    }

    /// 1回の打鍵を判定する。
    /// - Returns: 判定と、この打鍵で照合の食い違いを検出したか。
    public mutating func decide(_ key: KeyStroke, convertKey: ConvertKey, composerIsEmpty: Bool,
                                client: DirectTextClient, memory: inout AppModeMemory) -> (decision: Decision, detectedMismatch: Bool) {
        var detected = false
        // 1. 照合（振り分けより先に行う）
        if composerIsEmpty, !field.lockedToMarked, field.lastMethod == .replace {
            switch BufferConsistency.check(buffer: buffer, selectedRange: client.selectedRange, fetch: client.text(in:)) {
            case .mismatch:
                markUnsupported(bundleID: client.bundleID, memory: &memory)
                detected = true
            case .consistent:
                if BufferConsistency.comparedTail(of: buffer).utf16.count >= BufferConsistency.minimumVerifiedLength {
                    verified = true
                }
            case .notApplicable:
                break
            }
        }
        // 2. 振り分け
        let route = DirectKeyRoute.route(key, convertKey: convertKey, composerIsEmpty: composerIsEmpty) {
            field.method { ClientCapability.probe(selectedRange: client.selectedRange, fetch: client.text(in:)) }
        }
        switch route {
        case .marked:
            if composerIsEmpty { buffer.reset() } // 置き換えに対応していない欄で打ち始めた
            return (.marked, detected)
        case .convert:
            // 3. 照合済みでない欄では置き換えない
            return (verified ? .convert : .passThrough, detected)
        case .passThrough:
            return (.passThrough, detected)
        }
    }

    /// アプリへそのまま通した打鍵を打鍵バッファに記録する。
    public mutating func record(_ key: KeyStroke) {
        buffer.record(key)
    }
}
