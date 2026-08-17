#!/usr/bin/env bash
# fetch-voicevox.sh DEST_DIR [DEST_DIR]
#
# Download a fully offline VOICEVOX synthesis stack into DEST_DIR with the
# layout the shim expects:
#   DEST_DIR/core/lib/libvoicevox_core.so
#   DEST_DIR/core/include/voicevox_core.h
#   DEST_DIR/onnxruntime/lib/libvoicevox_onnxruntime.so
#   DEST_DIR/dict/open_jtalk_dic_utf_8-1.11/sys.dic
#   DEST_DIR/models/0.vvm
#
# ~90 MiB combined. Idempotent: re-running with the assets already in place
# does nothing unless FORCE=1.
#
# Pinned (together, not independently — a .vvm only loads on a new-enough
# CORE, and CORE wants the ONNX Runtime it was built against):
#   - VOICEVOX/voicevox_core       (MIT)
#   - VOICEVOX/onnxruntime-builder (CPU build CORE dlopen()s)
#   - r9y9/open_jtalk              (UTF-8 Open JTalk dictionary)
#   - VOICEVOX/voicevox_vvm        (Zundamon, style id 3)
#
# Attribution: audio generated with the voice model must be credited
# "VOICEVOX:ずんだもん" (see DEST_DIR/models/TERMS.txt written below).
#
# Requires: curl, sha256sum, tar, unzip.
set -eu -o pipefail

dest="${1:?usage: fetch-voicevox.sh DEST_DIR}"
force=0
[ "${FORCE:-0}" = "1" ] && force=1

core_version="0.17.0"
core_sha256="00a80c5688e2fde093a3e2c1a4c39170b1c86760d92638a554c8a971a9d97077"
core_url="https://github.com/VOICEVOX/voicevox_core/releases/download/${core_version}/voicevox_core-linux-x64-${core_version}.zip"

ort_version="1.23.2"
ort_sha256="0860cfbd5a80201b1bf95cae13ca2db8dc01f32f5674cc8193146047a9212fdb"
ort_url="https://github.com/VOICEVOX/onnxruntime-builder/releases/download/voicevox_onnxruntime-${ort_version}/voicevox_onnxruntime-linux-x64-${ort_version}.tgz"

dict_version="1.11.1"
dict_sha256="fe6ba0e43542cef98339abdffd903e062008ea170b04e7e2a35da805902f382a"
dict_url="https://github.com/r9y9/open_jtalk/releases/download/v${dict_version}/open_jtalk_dic_utf_8-1.11.tar.gz"

vvm_version="0.17.0"
vvm_sha256="ecd35374d4182cd883cba5040376f7f888cc6ba248b1c2f4cea07cdb34bb1318"
vvm_url="https://github.com/VOICEVOX/voicevox_vvm/releases/download/${vvm_version}/0.vvm"

if [ "$force" -eq 0 ] &&
    [ -f "$dest/core/lib/libvoicevox_core.so" ] &&
    [ -f "$dest/onnxruntime/lib/libvoicevox_onnxruntime.so" ] &&
    [ -f "$dest/dict/open_jtalk_dic_utf_8-1.11/sys.dic" ] &&
    [ -f "$dest/models/0.vvm" ]; then
    echo "voicevox: already present in $dest (set FORCE=1 to re-download)"
    exit 0
fi

cache="$(mktemp -d)"
work="$(mktemp -d)"
trap 'rm -rf "$cache" "$work"' EXIT

fetch() {
    local name="$1" url="$2" want="$3" out="$cache/$1"
    if [ -f "$out" ] && ! echo "$want  $out" | sha256sum -c --status; then
        echo "voicevox: cached $name failed checksum, re-downloading" >&2
        rm -f "$out"
    fi
    if [ ! -f "$out" ]; then
        echo "voicevox: downloading $url"
        curl -fsSL --retry 3 --retry-delay 2 -o "$out.part" "$url"
        mv "$out.part" "$out"
    fi
    if ! echo "$want  $out" | sha256sum -c --status; then
        echo "voicevox: checksum mismatch for $name" >&2
        echo "expected $want" >&2
        echo "actual   $(sha256sum "$out" | cut -d' ' -f1)" >&2
        exit 1
    fi
}

fetch "voicevox_core-${core_version}.zip" "$core_url" "$core_sha256"
fetch "voicevox_onnxruntime-${ort_version}.tgz" "$ort_url" "$ort_sha256"
fetch "open_jtalk_dic_utf_8-1.11.tar.gz" "$dict_url" "$dict_sha256"
fetch "0.vvm" "$vvm_url" "$vvm_sha256"

rm -rf "$dest/core" "$dest/onnxruntime" "$dest/dict" "$dest/models"
mkdir -p "$dest/core" "$dest/onnxruntime" "$dest/dict" "$dest/models"

unzip -q "$cache/voicevox_core-${core_version}.zip" -d "$work/core"
core_root="$work/core/voicevox_core-linux-x64-${core_version}"
for required in lib/libvoicevox_core.so include/voicevox_core.h LICENSE; do
    [ -e "$core_root/$required" ] || { echo "voicevox: core archive missing $required" >&2; exit 1; }
done
cp -r "$core_root/lib" "$core_root/include" "$dest/core/"
cp "$core_root/LICENSE" "$dest/core/LICENSE"

mkdir -p "$work/ort"
tar xzf "$cache/voicevox_onnxruntime-${ort_version}.tgz" -C "$work/ort"
ort_root="$work/ort/voicevox_onnxruntime-linux-x64-${ort_version}"
[ -e "$ort_root/lib/libvoicevox_onnxruntime.so" ] || { echo "voicevox: onnxruntime archive missing lib" >&2; exit 1; }
cp -r "$ort_root/lib" "$dest/onnxruntime/"
cp "$ort_root/TERMS.txt" "$dest/onnxruntime/TERMS.txt"

mkdir -p "$work/dict"
tar xzf "$cache/open_jtalk_dic_utf_8-1.11.tar.gz" -C "$work/dict"
[ -e "$work/dict/open_jtalk_dic_utf_8-1.11/sys.dic" ] || { echo "voicevox: dict archive missing sys.dic" >&2; exit 1; }
cp -r "$work/dict/open_jtalk_dic_utf_8-1.11" "$dest/dict/"

cp "$cache/0.vvm" "$dest/models/0.vvm"

cat >"$dest/models/TERMS.txt" <<'EOF'
VOICEVOX:ずんだもん — usage terms (summary)

Audio generated with this voice model may be used for commercial and
non-commercial purposes alike, provided it is credited as "VOICEVOX:ずんだもん"
(e.g. in a game's credits screen or README). Full terms:
https://github.com/VOICEVOX/voicevox_vvm/blob/main/README.md
EOF

echo "voicevox: installed into $dest"
