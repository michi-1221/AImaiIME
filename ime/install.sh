#!/bin/bash
# ビルド済みの AImaiIME.app を ~/Library/Input Methods にインストールする。
# 先に scripts/build.sh を実行しておくこと。インストール後の有効化は README の手順を参照。
set -euo pipefail

cd "$(dirname "$0")"
APP="build/AImaiIME.app"
DEST="$HOME/Library/Input Methods"

if [ ! -d "$APP" ]; then
  echo "$APP がありません。先に ./scripts/build.sh を実行してください。" >&2
  exit 1
fi

# 動いている古いプロセスを止める（入れ替えのため）
pkill -x AImaiIME 2>/dev/null || true

mkdir -p "$DEST"
rm -rf "$DEST/AImaiIME.app"
ditto "$APP" "$DEST/AImaiIME.app"
echo "インストールしました: $DEST/AImaiIME.app"

MODEL=$(defaults read dev.aimai.inputmethod.AImaiIME modelPath 2>/dev/null || echo "$HOME/Library/Application Support/AImaiIME/model.gguf")
MODEL="${MODEL/#\~/$HOME}"
if [ ! -f "$MODEL" ]; then
  echo "注意: モデルファイルがありません: $MODEL"
  echo "  defaults write dev.aimai.inputmethod.AImaiIME modelPath /path/to/model.gguf で指定してください。"
fi
echo "初回はログアウト・ログインのあと、システム設定 > キーボード > 入力ソース で AImai IME を追加してください。"
