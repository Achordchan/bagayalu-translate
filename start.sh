#!/bin/bash
set -euo pipefail

if (( $# != 0 )); then
    echo "用法：./start.sh" >&2
    echo "该 macOS 应用不需要端口或启动参数。" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_PATH="$SCRIPT_DIR/大佐翻译官v1.xcodeproj"
SCHEME="dazuofanyiguan"
PRODUCT_NAME="大佐翻译官v1"
TEMP_ROOT="${TMPDIR:-/tmp}"
TEMP_ROOT="${TEMP_ROOT%/}"
DERIVED_DATA_PATH="${DAZUO_DERIVED_DATA_PATH:-$TEMP_ROOT/dazuofanyiguan-local-${UID}}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/${PRODUCT_NAME}.app"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/$PRODUCT_NAME"

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "启动失败：未找到 xcodebuild。" >&2
    echo "请先安装 Xcode，并用 xcode-select 选择正确的 Developer 目录。" >&2
    exit 1
fi

if [[ ! -d "$PROJECT_PATH" ]]; then
    echo "启动失败：找不到 Xcode 工程：$PROJECT_PATH" >&2
    exit 1
fi

if running_pids="$(pgrep -x "$PRODUCT_NAME" 2>/dev/null)" && [[ -n "$running_pids" ]]; then
    echo "启动失败：$PRODUCT_NAME 已在运行（PID：${running_pids//$'\n'/, }）。" >&2
    echo "请先在应用菜单中退出已运行的实例。" >&2
    exit 1
fi

echo "正在构建 Debug 版本…"
xcodebuild \
    -quiet \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    build

if [[ ! -x "$APP_EXECUTABLE" ]]; then
    echo "启动失败：构建完成后未找到可执行文件：$APP_EXECUTABLE" >&2
    exit 1
fi

echo "构建完成，正在前台启动 ${PRODUCT_NAME}。"
echo "按 Ctrl+C 结束运行。"
exec "$APP_EXECUTABLE"
