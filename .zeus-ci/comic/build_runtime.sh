#!/usr/bin/env bash
set -euo pipefail
sdk=${1:-iphonesimulator}
root=$(cd "$(dirname "$0")/../.." && pwd)/..
root=$(cd "$root" && pwd)
output="$root/.zeus-ci/comic/build/$sdk"
mkdir -p "$output"
if [ ! -d "$root/.zeus-ci/comic/build/llama/.git" ]; then
  git clone --depth 1 --branch b5046 https://github.com/ggml-org/llama.cpp.git "$root/.zeus-ci/comic/build/llama"
fi
src="$root/.zeus-ci/comic/build/llama"
cmake -S "$src" -B "$output/cmake" -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=18.1 \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF \
  -DGGML_METAL=OFF -DGGML_OPENMP=OFF -DLLAMA_CURL=OFF -DGGML_NATIVE=OFF -DGGML_ACCELERATE=ON
cmake --build "$output/cmake" --target llama -j 3
if [ "$sdk" = iphonesimulator ]; then minimum=-mios-simulator-version-min=18.1; else minimum=-mios-version-min=18.1; fi
xcrun --sdk "$sdk" clang++ -std=c++17 -arch arm64 -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
  "$minimum" -I"$src/include" -I"$src/ggml/include" \
  -c "$root/Native/ComicRuntime/ZeusComicRuntime.cpp" -o "$output/wrapper.o"
python3 - "$output" <<'PY'
import pathlib,subprocess,sys
out=pathlib.Path(sys.argv[1]); libraries=sorted(out.joinpath('cmake').rglob('*.a'))
assert libraries
subprocess.run(['xcrun','libtool','-static','-o',str(out/'libzeuscomic.a'),str(out/'wrapper.o'),*map(str,libraries)],check=True)
PY
