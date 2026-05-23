#!/bin/zsh
set -euo pipefail

APP_PATH_DEFAULT="/Users/achordchan/Downloads/不同步的桌面/项目/dazuofanyiguan/大佐翻译官v1/大佐翻译官v1.app"
REPO_URL_DEFAULT="https://github.com/Achordchan/bagayalu-translate"
AUTHOR_DEFAULT="AchordChan"

APP_PATH="${1:-$APP_PATH_DEFAULT}"
OUT_DIR="${2:-$(pwd)/dist}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "[ERROR] 找不到 .app：$APP_PATH" >&2
  exit 1
fi

APP_BASENAME="$(basename "$APP_PATH")"
APP_DISPLAY_NAME="${APP_BASENAME%.app}"
VOLUME_NAME="$APP_DISPLAY_NAME"

mkdir -p "$OUT_DIR"
OUTPUT_DMG="$OUT_DIR/${APP_DISPLAY_NAME}.dmg"

TMP_DIR="$(mktemp -d)"
STAGING="$TMP_DIR/staging"
DMG_RW="$TMP_DIR/temp_rw.dmg"
BG_DIR="$STAGING/.background"
BG_PNG="$BG_DIR/background.png"

cleanup() {
  set +e
  if mount | grep -q "/Volumes/$VOLUME_NAME"; then
    hdiutil detach "/Volumes/$VOLUME_NAME" -quiet || true
  fi
  rm -rf "$TMP_DIR" || true
}
trap cleanup EXIT

mkdir -p "$STAGING"

# 1) 拷贝应用
cp -R "$APP_PATH" "$STAGING/"

# 2) Applications 快捷方式
ln -s "/Applications" "$STAGING/Applications"

# 3) 作者信息
cat > "$STAGING/作者信息.txt" <<EOF
应用：$APP_DISPLAY_NAME
作者：$AUTHOR_DEFAULT
仓库：$REPO_URL_DEFAULT
构建时间：$(date "+%Y-%m-%d %H:%M:%S")

说明：
- 将应用拖拽到 Applications 完成安装。
- 如遇权限提示，请在 系统设置 -> 隐私与安全 中开启屏幕录制/辅助功能。
EOF

# 4) 背景图（优先使用系统自带壁纸；如果找不到就不设置背景）
mkdir -p "$BG_DIR"
BG_SOURCE=""
for p in \
  "/System/Library/Desktop Pictures/Solid Colors/Blue.png" \
  "/System/Library/Desktop Pictures/Solid Colors/Purple.png" \
  "/System/Library/Desktop Pictures/Solid Colors/Blue Violet.png" \
  "/System/Library/Desktop Pictures/Solid Colors/Graphite.png" \
  "/System/Library/Desktop Pictures/Monterey Graphic.heic" \
  "/System/Library/Desktop Pictures/Ventura Graphic.heic" \
  "/System/Library/Desktop Pictures/Sonoma Graphic.heic" \
  "/System/Library/Desktop Pictures/Sequoia Graphic.heic"; do
  if [[ -f "$p" ]]; then
    BG_SOURCE="$p"
    break
  fi
done

if [[ -n "$BG_SOURCE" ]]; then
  if [[ "$BG_SOURCE" == *.png ]]; then
    cp "$BG_SOURCE" "$BG_PNG"
  else
    # heic -> png
    sips -s format png "$BG_SOURCE" --out "$BG_PNG" >/dev/null
  fi
fi

# 5) 先生成可写 DMG
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$DMG_RW" >/dev/null

# 6) 挂载 DMG 以写入 Finder 布局（.DS_Store）
ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_RW")"
DEVICE="$(echo "$ATTACH_OUTPUT" | awk '/Apple_HFS/ {print $1; exit}')"
MOUNT_POINT="/Volumes/$VOLUME_NAME"

# 等待挂载完成
for _ in {1..30}; do
  [[ -d "$MOUNT_POINT" ]] && break
  sleep 0.2
done

if [[ ! -d "$MOUNT_POINT" ]]; then
  echo "[ERROR] DMG 挂载失败：$MOUNT_POINT" >&2
  exit 1
fi

# 7) 设置 DMG 窗口布局/背景/图标位置
# 注：第一次运行可能会弹出‘控制 Finder’权限请求，需要允许。
osascript <<OSA
  tell application "Finder"
    tell disk "${VOLUME_NAME}"
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set bounds of container window to {160, 140, 860, 620}

      set theViewOptions to the icon view options of container window
      set arrangement of theViewOptions to not arranged
      set icon size of theViewOptions to 128
      set text size of theViewOptions to 12

      try
        if (exists file ".background:background.png") then
          set background picture of theViewOptions to file ".background:background.png"
        end if
      end try

      delay 0.2

      try
        set position of item "${APP_BASENAME}" to {200, 240}
      end try

      try
        set position of item "Applications" to {520, 240}
      end try

      try
        set position of item "作者信息.txt" to {360, 420}
      end try

      update without registering applications
      delay 0.8
      close
      open
      delay 0.6
      close
    end tell
  end tell
OSA

sync

# 8) 卸载并压缩为最终 DMG
hdiutil detach "$DEVICE" -quiet

hdiutil convert "$DMG_RW" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  -o "$OUTPUT_DMG" >/dev/null

echo "[OK] DMG 已生成：$OUTPUT_DMG"

echo "\n使用方式："
echo "  1) 给脚本执行权限：chmod +x scripts/build_dmg.sh"
echo "  2) 直接运行（默认使用你给的 app 路径）：./scripts/build_dmg.sh"
echo "  3) 或者指定 app 路径与输出目录：./scripts/build_dmg.sh \"/path/to/App.app\" \"./dist\""
