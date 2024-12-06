#!/bin/bash

# 设置应用程序路径为桌面上的位置
APP_PATH="/Users/achord/Desktop/大佐翻译官/大佐翻译官.app"
DMG_NAME="大佐翻译官.dmg"
TMP_DMG="temp.dmg"

# 创建资源目录
RESOURCES_DIR="./dmg_resources"
mkdir -p "${RESOURCES_DIR}"

# 确保背景图片存在
if [ ! -f "${RESOURCES_DIR}/background.svg" ]; then
    echo "错误：找不到背景图片 ${RESOURCES_DIR}/background.svg"
    exit 1
fi

# 转换SVG为PNG
# 需要安装 librsvg: brew install librsvg
rsvg-convert -w 660 -h 400 "${RESOURCES_DIR}/background.svg" -o "${RESOURCES_DIR}/background.png"

# 创建临时目录
TMP_DIR="./dmg_temp"
rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"

# 复制.app到临时目录
cp -r "${APP_PATH}" "${TMP_DIR}/"

# 创建Applications链接
ln -s /Applications "${TMP_DIR}/Applications"

# 创建临时目录用于背景
mkdir -p "${TMP_DIR}/.background"
cp "${RESOURCES_DIR}/background.png" "${TMP_DIR}/.background/"

# 创建临时DMG
hdiutil create -volname "大佐翻译官" -srcfolder "${TMP_DIR}" -ov -format UDRW "${TMP_DMG}"

# 挂载DMG
MOUNT_DIR="/Volumes/大佐翻译官"
hdiutil attach -readwrite "${TMP_DMG}"

# 等待DMG挂载
sleep 3

# 设置DMG窗口样式
echo '
   tell application "Finder"
     tell disk "大佐翻译官"
           open
           set current view of container window to icon view
           set toolbar visible of container window to false
           set statusbar visible of container window to false
           set the bounds of container window to {400, 100, 1060, 500}
           set theViewOptions to the icon view options of container window
           set arrangement of theViewOptions to not arranged
           set icon size of theViewOptions to 128
           set background picture of theViewOptions to file ".background:background.png"
           
           -- 设置图标位置
           set position of item "大佐翻译官.app" of container window to {160, 180}
           set position of item "Applications" of container window to {500, 180}
           
           update without registering applications
           delay 2
           close
     end tell
   end tell
' | osascript

# 强制更新
sync

# 等待一下确保所有更改都已写入
sleep 2

# 卸载DMG
hdiutil detach "${MOUNT_DIR}" -force

# 转换DMG为只读格式
hdiutil convert "${TMP_DMG}" -format UDZO -o "${DMG_NAME}"

# 清理临时文件
rm -f "${TMP_DMG}"
rm -rf "${TMP_DIR}"
rm -f "${RESOURCES_DIR}/background.png"

echo "DMG创建完成！文件位置：${DMG_NAME}" 