#!/bin/sh
set -eu

# Отдельная библиотека для Simulator; она не линкуется с macOS-клиентом.
loader_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
loader_work="${DERIVED_FILE_DIR}/LookinSimulatorLoader"
loader_output="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/LookinSimulatorLoader.dylib"
mkdir -p "$loader_work" "$(dirname "$loader_output")"
for loader_arch in arm64 x86_64; do
    xcrun clang -target "${loader_arch}-apple-ios14.0-simulator" -isysroot "$loader_sdk" \
        -dynamiclib -O2 -Wall -Wextra -Werror \
        "${SRCROOT}/LookinClient/Simulator/LookinSimulatorLoader.c" \
        -o "${loader_work}/${loader_arch}.dylib"
done
xcrun lipo -create "${loader_work}/arm64.dylib" "${loader_work}/x86_64.dylib" -output "$loader_output"
/usr/bin/codesign --force --sign - --timestamp=none "$loader_output"
