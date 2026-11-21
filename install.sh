#!/bin/sh
# AImai IME のインストール（GitHub Releases の最新版を入れる）
#   curl -fsSL https://raw.githubusercontent.com/michi-1221/AImaiIME/main/install.sh | sh
set -eu

# 全体を関数にして最後に呼ぶ（ダウンロードが途中で切れたときに、途中までのスクリプトを実行しないため）
main() {
  REPO="michi-1221/AImaiIME"
  BASE="https://github.com/$REPO/releases/latest/download"
  APP_DIR="$HOME/Library/Input Methods"
  MODEL_DIR="$HOME/Library/Application Support/AImaiIME"

  if [ "$(uname -s)" != "Darwin" ]; then
    echo "macOS 専用です。" >&2; exit 1
  fi
  if [ "$(uname -m)" != "arm64" ]; then
    echo "Apple シリコン（M1 以降）の Mac が必要です。" >&2; exit 1
  fi
  MAJOR=$(sw_vers -productVersion | cut -d. -f1)
  if [ "$MAJOR" -lt 14 ]; then
    echo "macOS 14 以降が必要です（この Mac は $(sw_vers -productVersion)）。" >&2; exit 1
  fi

  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT

  echo "ダウンロードしています…"
  curl -fL -# -o "$TMP/AImaiIME.app.zip" "$BASE/AImaiIME.app.zip"
  curl -fL -# -o "$TMP/model-q8_0.gguf" "$BASE/model-q8_0.gguf"
  curl -fsSL -o "$TMP/SHA256SUMS" "$BASE/SHA256SUMS"

  echo "ファイルを確かめています…"
  (cd "$TMP" && shasum -a 256 -c SHA256SUMS >/dev/null) || {
    echo "ダウンロードしたファイルのチェックサムが一致しません。時間をおいてもう一度試してください。" >&2; exit 1
  }

  pkill -x AImaiIME 2>/dev/null || true
  mkdir -p "$APP_DIR" "$MODEL_DIR"
  rm -rf "$APP_DIR/AImaiIME.app"
  ditto -x -k "$TMP/AImaiIME.app.zip" "$APP_DIR"
  xattr -dr com.apple.quarantine "$APP_DIR/AImaiIME.app" 2>/dev/null || true
  mv "$TMP/model-q8_0.gguf" "$MODEL_DIR/model.gguf"

  cat <<'MSG'

インストールしました。続けて、次の3つを手で行ってください。
  1. いったんログアウトして、ログインし直す。
  2. 「システム設定 > キーボード > 入力ソース > 編集… > ＋」で AImai IME を追加する。
  3. 入力ソースを AImai IME に切り替える。
MSG
}

main "$@"
