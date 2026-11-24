# AImai IME

**曖昧に打っても正確に変換される**

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

打った文字は、変換するまで下線付きの未確定文字として表示されます。打つ手が1秒止まると、変換したらどうなるかがカーソルの下に小さく表示されます。

- **変換キー**: 既定は Space です。設定画面の枠をクリックして使いたいキーを押すと、そのキーに変わります。Tab や ⌥Space のような組み合わせのほか、右 ⌘ のような修飾キーを単独で1回押すことも選べます。英語もよく打つ場合は、Space 以外のキーにすると、Space で空白を入れられます。

## ライセンスとクレジット

- コード: [MIT License](LICENSE)
- 変換モデル（Releases の `model-q8_0.gguf`）: [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)。次のモデルをもとに、打ち間違いを含むローマ字から日本語へ変換するよう追加学習し、GGUF（Q8_0）に変換したものです。
  - [zenz-v3.1-small](https://huggingface.co/Miwa-Keita/zenz-v3.1-small)（Miwa-Keita、CC BY-SA 4.0）
  - その元になった [ku-nlp/gpt2-small-japanese-char](https://huggingface.co/ku-nlp/gpt2-small-japanese-char)（CC BY-SA 4.0）
- 推論には [llama.cpp](https://github.com/ggml-org/llama.cpp)（MIT License）を使い、アプリに同梱しています。ライセンス文は [ime/THIRD_PARTY_NOTICES.md](ime/THIRD_PARTY_NOTICES.md) にあります。

## リンク

- サイト: https://michi-1221.github.io/AImaiIME/
- リポジトリ: https://github.com/michi-1221/AImaiIME
