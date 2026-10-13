#!/bin/zsh
set -euo pipefail
root=${0:A:h:h}
probe=$(mktemp -d /tmp/curtain-window-recovery.XXXXXX)
trap 'rm -rf "$probe"' EXIT
compile_target="$(uname -m)-apple-macosx26.0"
cp "$root/tests/fixtures/window-session-recovery.swift" "$probe/main.swift"
swiftc -swift-version 5 -target "$compile_target" -emit-library -emit-module \
  -module-name AgentCurtainCore -emit-module-path "$probe/AgentCurtainCore.swiftmodule" \
  -o "$probe/libAgentCurtainCore.dylib" "$root"/Sources/AgentCurtainCore/*.swift
swiftc -swift-version 5 -target "$compile_target" -I "$probe" -L "$probe" \
  -lAgentCurtainCore -Xlinker -rpath -Xlinker "$probe" \
  "$root/Sources/AgentCurtain/WindowSessionController.swift" "$probe/main.swift" -o "$probe/test"
"$probe/test"
