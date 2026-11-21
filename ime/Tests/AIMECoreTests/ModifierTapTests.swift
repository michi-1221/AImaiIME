import XCTest
@testable import AIMECore

final class ModifierTapTests: XCTestCase {
    private let t0: TimeInterval = 1000
    // NSEvent.modifierFlags の rawValue（デバイス依存ビットを含む）
    private let cmd: UInt = 1 << 20, opt: UInt = 1 << 19, ctrl: UInt = 1 << 18, shift: UInt = 1 << 17

    /// 各修飾キーを押したときのフラグ（デバイスビット込み）
    private func down(_ k: ModifierKey) -> UInt { k.familyFlag | k.deviceBit }

    func testEveryModifierKeyFiresOnSingleTap() {
        for k in ModifierKey.allCases {
            var t = ModifierTap(target: k)
            XCTAssertNil(t.flagsChanged(keyCode: k.keyCode, rawFlags: down(k), timestamp: t0), "\(k)")
            XCTAssertEqual(t.flagsChanged(keyCode: k.keyCode, rawFlags: 0, timestamp: t0 + (0.2)), k, "\(k)")
            // 二重には数えない
            XCTAssertNil(t.flagsChanged(keyCode: k.keyCode, rawFlags: 0, timestamp: t0 + (0.3)), "\(k)")
        }
    }

    func testOnlyTargetKeyCounts() {
        var t = ModifierTap(target: .rightCommand)
        XCTAssertNil(t.flagsChanged(keyCode: ModifierKey.leftCommand.keyCode, rawFlags: down(.leftCommand), timestamp: t0))
        XCTAssertNil(t.flagsChanged(keyCode: ModifierKey.leftCommand.keyCode, rawFlags: 0, timestamp: t0 + (0.1)))
        // 左 ⌘ を押している間の右 ⌘ は数えない
        XCTAssertNil(t.flagsChanged(keyCode: ModifierKey.leftCommand.keyCode, rawFlags: down(.leftCommand), timestamp: t0))
        XCTAssertNil(t.flagsChanged(keyCode: 54, rawFlags: down(.leftCommand) | down(.rightCommand), timestamp: t0))
        XCTAssertNil(t.flagsChanged(keyCode: 54, rawFlags: down(.leftCommand), timestamp: t0 + (0.1)))
        // 右 ⌥ や右 ⇧ などほかの修飾キーは対象外
        XCTAssertNil(t.flagsChanged(keyCode: 61, rawFlags: down(.rightOption), timestamp: t0))
        XCTAssertNil(t.flagsChanged(keyCode: 61, rawFlags: 0, timestamp: t0 + (0.1)))
    }

    func testOtherModifierHeldOrPressedCancels() {
        // 先に Shift を押していた
        var t = ModifierTap(target: .rightOption)
        XCTAssertNil(t.flagsChanged(keyCode: 61, rawFlags: down(.rightOption) | down(.leftShift), timestamp: t0))
        XCTAssertNil(t.flagsChanged(keyCode: 61, rawFlags: down(.leftShift), timestamp: t0 + (0.1)))
        // 押している間にほかの修飾キーを押した
        var u = ModifierTap(target: .rightOption)
        _ = u.flagsChanged(keyCode: 61, rawFlags: down(.rightOption), timestamp: t0)
        _ = u.flagsChanged(keyCode: 56, rawFlags: down(.rightOption) | down(.leftShift), timestamp: t0)
        XCTAssertNil(u.flagsChanged(keyCode: 61, rawFlags: down(.leftShift), timestamp: t0 + (0.1)))
        // 同じ種類の反対側（左右の ⇧）
        var v = ModifierTap(target: .rightShift)
        XCTAssertNil(v.flagsChanged(keyCode: 60, rawFlags: down(.rightShift) | down(.leftShift), timestamp: t0))
        XCTAssertNil(v.flagsChanged(keyCode: 60, rawFlags: down(.leftShift), timestamp: t0 + (0.1)))
    }

    func testKeyDownMouseAndCancelDuringPress() {
        var t = ModifierTap(target: .leftControl)
        _ = t.flagsChanged(keyCode: 59, rawFlags: down(.leftControl), timestamp: t0)
        t.keyDown()
        XCTAssertNil(t.flagsChanged(keyCode: 59, rawFlags: 0, timestamp: t0 + (0.1)))
        _ = t.flagsChanged(keyCode: 59, rawFlags: down(.leftControl), timestamp: t0)
        t.cancel()
        XCTAssertNil(t.flagsChanged(keyCode: 59, rawFlags: 0, timestamp: t0 + (0.1)))
    }

    func testKeyDownNotSeenByImeIsDetected() {
        var t = ModifierTap(target: .rightCommand)
        _ = t.flagsChanged(keyCode: 54, rawFlags: down(.rightCommand), timestamp: t0)
        // 押している間（t0+0.1）に keyDown があった → ⌘C など
        XCTAssertNil(t.flagsChanged(keyCode: 54, rawFlags: 0, timestamp: t0 + 0.3, lastKeyDownAt: t0 + 0.1))
        // 押す前の keyDown なら数える
        _ = t.flagsChanged(keyCode: 54, rawFlags: down(.rightCommand), timestamp: t0)
        XCTAssertEqual(t.flagsChanged(keyCode: 54, rawFlags: 0, timestamp: t0 + 0.3, lastKeyDownAt: t0 - 0.05), .rightCommand)
    }

    func testMouseDownAndScrollDuringPressAreDetected() {
        var t = ModifierTap(target: .leftShift)
        _ = t.flagsChanged(keyCode: 56, rawFlags: down(.leftShift), timestamp: t0)
        XCTAssertNil(t.flagsChanged(keyCode: 56, rawFlags: 0, timestamp: t0 + 0.3, lastMouseDownAt: t0 + 0.1))
        // ⇧+スクロール（横スクロール）、⌃+スクロール（ズーム）
        _ = t.flagsChanged(keyCode: 56, rawFlags: down(.leftShift), timestamp: t0)
        XCTAssertNil(t.flagsChanged(keyCode: 56, rawFlags: 0, timestamp: t0 + 0.3, lastScrollAt: t0 + 0.2))
        _ = t.flagsChanged(keyCode: 56, rawFlags: down(.leftShift), timestamp: t0)
        XCTAssertEqual(t.flagsChanged(keyCode: 56, rawFlags: 0, timestamp: t0 + 0.3, lastScrollAt: t0 - 1), .leftShift)
    }

    func testDelayedProcessingDoesNotCauseWrongConversion() {
        // IME が変換の計算で詰まり、押した・離したイベントを続けて処理する。処理は同時でも、
        // イベントの時刻と、システムの最後の keyDown の絶対時刻で判定するので、誤って変換しない。
        var t = ModifierTap(target: .rightCommand)
        // ⌘C（keyDown は t0+0.1）を挟んだ。処理時にはどちらも「今」でも、時刻は保たれている
        _ = t.flagsChanged(keyCode: 54, rawFlags: down(.rightCommand), timestamp: t0)
        XCTAssertNil(t.flagsChanged(keyCode: 54, rawFlags: 0, timestamp: t0 + 0.25, lastKeyDownAt: t0 + 0.1))
        // 長く押していた（0.8 秒）のも、処理が続けて行われても数えない
        _ = t.flagsChanged(keyCode: 54, rawFlags: down(.rightCommand), timestamp: t0)
        XCTAssertNil(t.flagsChanged(keyCode: 54, rawFlags: 0, timestamp: t0 + 0.8))
        // 本当に単独で短く押した場合は、処理が遅れても変換する
        _ = t.flagsChanged(keyCode: 54, rawFlags: down(.rightCommand), timestamp: t0)
        XCTAssertEqual(t.flagsChanged(keyCode: 54, rawFlags: 0, timestamp: t0 + 0.2, lastKeyDownAt: t0 - 3), .rightCommand)
    }

    func testLongPressDoesNotFire() {
        var t = ModifierTap(target: .rightCommand)
        _ = t.flagsChanged(keyCode: 54, rawFlags: down(.rightCommand), timestamp: t0)
        XCTAssertNil(t.flagsChanged(keyCode: 54, rawFlags: 0, timestamp: t0 + (0.6)))
        // 上限ちょうどは数える
        _ = t.flagsChanged(keyCode: 54, rawFlags: down(.rightCommand), timestamp: t0)
        XCTAssertEqual(t.flagsChanged(keyCode: 54, rawFlags: 0, timestamp: t0 + (0.5)), .rightCommand)
    }

    func testWorksWithoutDeviceBits() {
        var t = ModifierTap(target: .rightCommand)
        _ = t.flagsChanged(keyCode: 54, rawFlags: cmd, timestamp: t0)
        XCTAssertEqual(t.flagsChanged(keyCode: 54, rawFlags: 0, timestamp: t0 + (0.1)), .rightCommand)
    }

    func testRecordingModeAcceptsAnyModifierAndCapsLockIsIgnored() {
        var t = ModifierTap() // 変換キーの記録用: どの修飾キーでもよい
        _ = t.flagsChanged(keyCode: 62, rawFlags: down(.rightControl), timestamp: t0)
        XCTAssertEqual(t.flagsChanged(keyCode: 62, rawFlags: 0, timestamp: t0 + (0.2)), .rightControl)
        // Caps Lock（57）・fn（63）は変換キーにできない
        XCTAssertNil(t.flagsChanged(keyCode: 57, rawFlags: 1 << 16, timestamp: t0))
        XCTAssertNil(t.flagsChanged(keyCode: 57, rawFlags: 0, timestamp: t0 + (0.1)))
        XCTAssertNil(ModifierKey(keyCode: 57))
        XCTAssertNil(ModifierKey(keyCode: 63))
    }

    func testKeyCodesMatchCarbon() {
        XCTAssertEqual(ModifierKey.rightCommand.keyCode, 54)
        XCTAssertEqual(ModifierKey.leftCommand.keyCode, 55)
        XCTAssertEqual(ModifierKey.leftShift.keyCode, 56)
        XCTAssertEqual(ModifierKey.leftOption.keyCode, 58)
        XCTAssertEqual(ModifierKey.leftControl.keyCode, 59)
        XCTAssertEqual(ModifierKey.rightShift.keyCode, 60)
        XCTAssertEqual(ModifierKey.rightOption.keyCode, 61)
        XCTAssertEqual(ModifierKey.rightControl.keyCode, 62)
        XCTAssertEqual(Set(ModifierKey.allCases.map(\.keyCode)).count, 8)
        XCTAssertEqual(Set(ModifierKey.allCases.map(\.deviceBit)).count, 8)
    }
}

final class ModifierConvertKeyTests: XCTestCase {
    func testFormatsRoundTrip() throws {
        let names: [(String, ModifierKey)] = [
            ("rightcmd", .rightCommand), ("leftcmd", .leftCommand),
            ("rightoption", .rightOption), ("leftoption", .leftOption),
            ("rightctrl", .rightControl), ("leftctrl", .leftControl),
            ("rightshift", .rightShift), ("leftshift", .leftShift),
        ]
        for (text, key) in names {
            let k = try XCTUnwrap(ConvertKey.parse(text), text)
            XCTAssertEqual(k.modifierKey, key, text)
            XCTAssertEqual(k.description, text)
            XCTAssertEqual(ConvertKey.parse(k.description), k)
            XCTAssertEqual(k.displayString, key.displayName)
            XCTAssertNotNil(k.conflictNote)
            XCTAssertEqual(k, .modifierOnly(key))
        }
        // 別名・大文字小文字・空白
        XCTAssertEqual(ConvertKey.parse(" RightCommand ")?.modifierKey, .rightCommand)
        XCTAssertEqual(ConvertKey.parse("leftopt")?.modifierKey, .leftOption)
        XCTAssertEqual(ConvertKey.parse("leftalt")?.modifierKey, .leftOption)
        XCTAssertEqual(ConvertKey.parse("rightcontrol")?.modifierKey, .rightControl)
        XCTAssertEqual(ConvertKey.parse("rightcmd")?.description, "rightcmd") // 今までの書式
    }

    func testRejectsCombinationsAndUnknownNames() {
        for text in ["cmd+rightcmd", "shift+leftshift", "right", "rightfn", "rightcaps", "middlecmd", "rightcmd+a", "cmd"] {
            XCTAssertNil(ConvertKey.parse(text), text)
        }
    }

    func testDefaultStaysSpaceAndMatchesOnlySyntheticStroke() {
        XCTAssertEqual(ConvertKey.defaultKey, .space)
        let k = ConvertKey.modifierOnly(.leftShift)
        XCTAssertFalse(k.matches(KeyStroke(keyCode: 49, characters: " ")))
        XCTAssertFalse(k.matches(KeyStroke(keyCode: 0, modifiers: .shift, characters: "A")))
        XCTAssertTrue(k.matches(KeyStroke(keyCode: 56, characters: nil)))
        XCTAssertEqual(ComposerKey.classify(KeyStroke(keyCode: 56, characters: nil), convertKey: k), .convert)
        XCTAssertNotEqual(ComposerKey.classify(KeyStroke(keyCode: 56, characters: nil), convertKey: .space), .convert)
        XCTAssertNil(ConvertKey.space.modifierKey)
    }

    func testSettingsLoadsModifierKey() throws {
        let suite = "aime-test-\(UUID())"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        d.set("rightshift", forKey: Settings.Key.convertKey)
        let s = Settings.load(from: d)
        XCTAssertEqual(s.convertKey.modifierKey, .rightShift)
        XCTAssertEqual(s.invalidValues, [])
    }
}
