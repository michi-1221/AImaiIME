# AImai IME

**急いで打ってもちゃんと伝わる**

![AImai IME のデモ](docs/demo.gif)

AImai IME は macOS 用の日本語入力です。

- 英数モードのまま、空白なしのローマ字で文を最後まで打ちます。
- 変換キー（既定は Space）を1回押すと、文ごと漢字かな交じりの日本語になります。
- 隣のキーを押してしまった、1文字多い・抜けた、順番が入れ替わった、といった打ち間違いがあっても、前後の文字から読み取って変換します。
- 変換は Mac の中で動く小さな言語モデルで行います。打った文章はネットワークに送られません。

## 動作環境

- macOS 14 以降
- Apple シリコン（M1 以降）の Mac

## インストール

ターミナルで次の1行を実行します。

```sh
curl -fsSL https://raw.githubusercontent.com/michi-1221/AImaiIME/main/install.sh | sh
```

終わったら、次の3つを手で行います（インストールの最後にも表示されます）。

1. いったんログアウトして、ログインし直す。
2. 「システム設定 > キーボード > 入力ソース > 編集… > ＋」で AImai IME を追加する。
3. 入力ソースを AImai IME に切り替える。

Claude Code などの AI エージェントに頼む場合は、次の文をそのまま貼ってください。

```
AImai IME をこの Mac にインストールしてください。ターミナルで curl -fsSL https://raw.githubusercontent.com/michi-1221/AImaiIME/main/install.sh | sh を実行し、終わったら入力ソースに AImai IME を追加する手順を案内してください。
```

## 使い方

1. 入力ソースを AImai IME にして、ローマ字で文を打ちます（例: `ekimaenokafedematteimasu`）。
2. 変換キー（既定は Space）を押すと、日本語に変わります（例: 駅前のカフェで待っています）。
3. 続けて変換キーを押すと、次の候補に切り替わります。

### 設定

メニューバーの入力メニューで AImai IME を選び、「AImai IME の設定…」を開くと変えられます。

- **入力の方式**
  - 未確定文字モード（既定）: 打った文字を下線付きの未確定文字として持ち、変換キーで変換します。
  - 直接モード: 打った文字はすぐ入力欄に入り、変換キーでカーソル直前のローマ字を日本語に置き換えます。直接の置き換えに対応していない入力欄（ターミナルなど）では、自動で未確定文字モードと同じ動きになります。
- **変換キー**: Space のほか、Tab や ⌥Space などに変えられます。

## アンインストール

1. 「システム設定 > キーボード > 入力ソース」で AImai IME を外す。
2. ターミナルで次を実行する。

```sh
rm -rf ~/Library/Input\ Methods/AImaiIME.app ~/Library/Application\ Support/AImaiIME
defaults delete dev.aimai.inputmethod.AImaiIME 2>/dev/null
```

## ソースからビルドする

Xcode のコマンドラインツール（Swift 5.10 以降）が必要です。

```sh
cd ime
./scripts/build.sh      # ime/build/AImaiIME.app を作る（llama.cpp のビルド済みフレームワークを自動で取得）
./install.sh            # ~/Library/Input Methods にコピーする
```

モデル（`model-q8_0.gguf`）は [Releases](https://github.com/michi-1221/AImaiIME/releases) から取得し、`~/Library/Application Support/AImaiIME/model.gguf` に置いてください。

## ライセンスとクレジット

- コード: [MIT License](LICENSE)
- 変換モデル（Releases の `model-q8_0.gguf`）: [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)。次のモデルをもとに、打ち間違いを含むローマ字から日本語へ変換するよう追加学習し、GGUF（Q8_0）に変換したものです。
  - [zenz-v3.1-small](https://huggingface.co/Miwa-Keita/zenz-v3.1-small)（Miwa-Keita、CC BY-SA 4.0）
  - その元になった [ku-nlp/gpt2-small-japanese-char](https://huggingface.co/ku-nlp/gpt2-small-japanese-char)（CC BY-SA 4.0）
- 推論には [llama.cpp](https://github.com/ggml-org/llama.cpp)（MIT License）を使い、アプリに同梱しています。ライセンス文は [ime/THIRD_PARTY_NOTICES.md](ime/THIRD_PARTY_NOTICES.md) にあります。

## リンク

- サイト: https://michi-1221.github.io/AImaiIME/
- リポジトリ: https://github.com/michi-1221/AImaiIME
