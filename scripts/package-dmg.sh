#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
architecture="$(uname -m)"
mkdir -p .build dist
staging="$(mktemp -d "$PWD/.build/dmg-stage.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

# Build a separate bundle so packaging does not overwrite a running app.
MACBEAT_APP_OUTPUT="$staging/MacBeat.app" bash scripts/build.sh
ln -s /Applications "$staging/Applications"
cat > "$staging/安装说明.txt" <<'INSTALL'
MacBeat

将 MacBeat.app 拖入 Applications，然后从“应用程序”打开。
MacBeat 位于菜单栏，不显示 Dock 图标。

当前版本未使用 Developer ID 签名，也未经过 Apple 公证。
请仅从项目官方仓库下载；首次打开时 macOS 可能显示安全提示。
如果系统阻止打开，请核对下载来源并参考 README 的安装说明。

退出旧版本后再替换应用。更新后需要重新开启保持运行。
项目：https://github.com/xvshiting/macbeat
INSTALL

mkdir -p dist
dmg="$PWD/dist/MacBeat-$version-$architecture.dmg"
hdiutil create -volname MacBeat -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg"
hdiutil verify "$dmg"
(cd dist && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
echo "Packaged: $dmg"
