#!/usr/bin/env bash
# fetch-voicevox.sh DEST_DIR
#
# Download a fully offline VOICEVOX synthesis stack into DEST_DIR with the
# layout the shim expects (LIBEXT is `so` on Linux, `dylib` on macOS):
#   DEST_DIR/core/lib/libvoicevox_core.LIBEXT
#   DEST_DIR/core/include/voicevox_core.h
#   DEST_DIR/onnxruntime/lib/libvoicevox_onnxruntime.LIBEXT
#   DEST_DIR/dict/open_jtalk_dic_utf_8-1.11/sys.dic
#   DEST_DIR/models/0.vvm
#
# ~90 MiB combined. Idempotent: re-running with the assets already in place
# does nothing unless FORCE=1.
#
# Platforms: linux-x64, macOS arm64 (Apple silicon), macOS x86_64 (Intel).
#
# Pinned (together, not independently — a .vvm only loads on a new-enough
# CORE, and CORE wants the ONNX Runtime it was built against):
#   - VOICEVOX/voicevox_core       (MIT)
#   - VOICEVOX/onnxruntime-builder (CPU build CORE dlopen()s)
#   - r9y9/open_jtalk              (UTF-8 Open JTalk dictionary)
#   - VOICEVOX/voicevox_vvm        (0.vvm: ずんだもん / 四国めたん /
#                                   春日部つむぎ / 雨晴はう)
#
# Attribution: audio generated with a voice model must be credited to the
# character that spoke it, e.g. "VOICEVOX:ずんだもん" (see
# DEST_DIR/models/TERMS.txt written below).
#
# Requires: curl, tar, unzip, and sha256sum (Linux) or shasum (macOS).
set -eu -o pipefail

dest="${1:?usage: fetch-voicevox.sh DEST_DIR}"
force=0
[ "${FORCE:-0}" = "1" ] && force=1

# --- platform detection -----------------------------------------------------
# The two projects disagree on how to spell 64-bit Intel macOS: voicevox_core
# ships `osx-x64`, onnxruntime-builder ships `osx-x86_64`. Keep them separate.
case "$(uname -s)" in
    Linux)  os=linux; libext=so    ;;
    Darwin) os=osx;   libext=dylib ;;
    *) echo "voicevox: unsupported OS $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
    x86_64|amd64)  arch=x64;   ort_arch=x86_64 ;;
    arm64|aarch64) arch=arm64; ort_arch=arm64  ;;
    *) echo "voicevox: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
[ "$os" = linux ] && ort_arch="$arch"   # linux-x64, not linux-x86_64
platform="$os-$arch"

core_version="0.17.0"
ort_version="1.23.2"
case "$platform" in
    linux-x64)
        core_sha256="00a80c5688e2fde093a3e2c1a4c39170b1c86760d92638a554c8a971a9d97077"
        ort_sha256="0860cfbd5a80201b1bf95cae13ca2db8dc01f32f5674cc8193146047a9212fdb" ;;
    osx-arm64)
        core_sha256="3769f7a7a503264cd9bf2f6f0f7222daf63549ab187f91c2177e78afd209f850"
        ort_sha256="010bdb42fefb4ca73429c0d8d3df2cb20a3b6ca0affebac3c05dc450b9fe338d" ;;
    osx-x64)
        core_sha256="58464f0e066b6b962a21656938e4cd2e372ca10ff9c54404893b43fad79d2a37"
        ort_sha256="48d86ebd4a588e179c3e7e91741c76b5cf7606b30fd250eee2cf62857e8fca0e" ;;
    *)
        echo "voicevox: no pinned assets for $platform" >&2
        echo "  (supported: linux-x64, osx-arm64, osx-x64)" >&2
        exit 1 ;;
esac

core_url="https://github.com/VOICEVOX/voicevox_core/releases/download/${core_version}/voicevox_core-${platform}-${core_version}.zip"
ort_url="https://github.com/VOICEVOX/onnxruntime-builder/releases/download/voicevox_onnxruntime-${ort_version}/voicevox_onnxruntime-${os}-${ort_arch}-${ort_version}.tgz"

dict_version="1.11.1"
dict_sha256="fe6ba0e43542cef98339abdffd903e062008ea170b04e7e2a35da805902f382a"
dict_url="https://github.com/r9y9/open_jtalk/releases/download/v${dict_version}/open_jtalk_dic_utf_8-1.11.tar.gz"

vvm_version="0.17.0"
vvm_sha256="ecd35374d4182cd883cba5040376f7f888cc6ba248b1c2f4cea07cdb34bb1318"
vvm_url="https://github.com/VOICEVOX/voicevox_vvm/releases/download/${vvm_version}/0.vvm"

if [ "$force" -eq 0 ] &&
    [ -f "$dest/core/lib/libvoicevox_core.$libext" ] &&
    [ -f "$dest/onnxruntime/lib/libvoicevox_onnxruntime.$libext" ] &&
    [ -f "$dest/dict/open_jtalk_dic_utf_8-1.11/sys.dic" ] &&
    [ -f "$dest/models/0.vvm" ]; then
    echo "voicevox: already present in $dest (set FORCE=1 to re-download)"
    exit 0
fi

# macOS ships `shasum` rather than coreutils' `sha256sum`.
if command -v sha256sum >/dev/null 2>&1; then
    sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
    sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
    echo "voicevox: need sha256sum or shasum in PATH" >&2; exit 1
fi

cache="$(mktemp -d)"
work="$(mktemp -d)"
trap 'rm -rf "$cache" "$work"' EXIT

fetch() {
    local name="$1" url="$2" want="$3" out="$cache/$1"
    if [ -f "$out" ] && [ "$(sha256 "$out")" != "$want" ]; then
        echo "voicevox: cached $name failed checksum, re-downloading" >&2
        rm -f "$out"
    fi
    if [ ! -f "$out" ]; then
        echo "voicevox: downloading $url"
        curl -fsSL --retry 3 --retry-delay 2 -o "$out.part" "$url"
        mv "$out.part" "$out"
    fi
    local got; got="$(sha256 "$out")"
    if [ "$got" != "$want" ]; then
        echo "voicevox: checksum mismatch for $name" >&2
        echo "expected $want" >&2
        echo "actual   $got" >&2
        exit 1
    fi
}

echo "voicevox: platform $platform"
fetch "voicevox_core-${core_version}.zip" "$core_url" "$core_sha256"
fetch "voicevox_onnxruntime-${ort_version}.tgz" "$ort_url" "$ort_sha256"
fetch "open_jtalk_dic_utf_8-1.11.tar.gz" "$dict_url" "$dict_sha256"
fetch "0.vvm" "$vvm_url" "$vvm_sha256"

rm -rf "$dest/core" "$dest/onnxruntime" "$dest/dict" "$dest/models"
mkdir -p "$dest/core" "$dest/onnxruntime" "$dest/dict" "$dest/models"

unzip -q "$cache/voicevox_core-${core_version}.zip" -d "$work/core"
core_root="$work/core/voicevox_core-${platform}-${core_version}"
for required in "lib/libvoicevox_core.$libext" include/voicevox_core.h LICENSE; do
    [ -e "$core_root/$required" ] || { echo "voicevox: core archive missing $required" >&2; exit 1; }
done
cp -R "$core_root/lib" "$core_root/include" "$dest/core/"
cp "$core_root/LICENSE" "$dest/core/LICENSE"

mkdir -p "$work/ort"
tar xzf "$cache/voicevox_onnxruntime-${ort_version}.tgz" -C "$work/ort"
ort_root="$work/ort/voicevox_onnxruntime-${os}-${ort_arch}-${ort_version}"
[ -e "$ort_root/lib/libvoicevox_onnxruntime.$libext" ] || { echo "voicevox: onnxruntime archive missing lib" >&2; exit 1; }
# -R (not -L): the shipped libvoicevox_onnxruntime.$libext is a symlink to the
# versioned file next to it, and CORE dlopen()s it by that unversioned name.
cp -R "$ort_root/lib" "$dest/onnxruntime/"
cp "$ort_root/TERMS.txt" "$dest/onnxruntime/TERMS.txt"

mkdir -p "$work/dict"
tar xzf "$cache/open_jtalk_dic_utf_8-1.11.tar.gz" -C "$work/dict"
[ -e "$work/dict/open_jtalk_dic_utf_8-1.11/sys.dic" ] || { echo "voicevox: dict archive missing sys.dic" >&2; exit 1; }
cp -R "$work/dict/open_jtalk_dic_utf_8-1.11" "$dest/dict/"

cp "$cache/0.vvm" "$dest/models/0.vvm"

cat >"$dest/models/TERMS.txt" <<'EOF'
0.vvm — usage terms (summary)

The model holds four characters, addressed by VOICEVOX style id:

  ずんだもん     ノーマル 3, あまあま 1, ツンツン 7, セクシー 5
  四国めたん     ノーマル 2, あまあま 0, ツンツン 6, セクシー 4
  春日部つむぎ   ノーマル 8
  雨晴はう       ノーマル 10

Audio generated with them may be used for commercial and non-commercial
purposes alike, provided it is credited to whichever character spoke —
"VOICEVOX:ずんだもん", "VOICEVOX:四国めたん", and so on (e.g. in a game's
credits screen or README). Full terms:
https://github.com/VOICEVOX/voicevox_vvm/blob/main/README.md
EOF

echo "voicevox: installed into $dest"
