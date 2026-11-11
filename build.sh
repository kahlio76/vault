#!/bin/zsh
# Builds build/Vault.app (ad-hoc signed, runs on this Mac).
#   ./build.sh            build only
#   ./build.sh --install  also copy the app to ~/Applications
set -euo pipefail
cd "${0:A:h}"

# fail early if the page script has a syntax error (the app would otherwise start with a blank page)
if command -v node >/dev/null; then
  python3 - <<'PY' > /tmp/vault-page-script.js
import re
s = open("Resources/shell.html").read()
print(re.findall(r"<script>\n(.*?)</script>", s, re.S)[-1])
PY
  node --check /tmp/vault-page-script.js
  node --check Resources/render.js
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Vault"

APP="build/Vault.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Vault"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/shell.html Resources/render.js "$APP/Contents/Resources/"
cp -R Resources/katex "$APP/Contents/Resources/katex"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null
echo "built $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Vault.app"
  cp -R "$APP" "$HOME/Applications/Vault.app"
  echo "installed ~/Applications/Vault.app"
fi
