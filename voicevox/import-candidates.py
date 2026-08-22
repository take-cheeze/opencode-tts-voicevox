#!/usr/bin/env python3
"""Import collected unknown words into the VOICEVOX pronunciation dictionary.

claude-tts-speak and claude-tts-speakd write identifiers they do not
recognize to ~/.local/share/opencode-tts-speakd/unknown_words.txt (one
surface word per line). This tool moves those into the dictionary in one of
two ways:

  --write             (manual curation) appends candidates to
                       voicevox/user_dict_terms.tsv with a placeholder
                       pronunciation Open JTalk will reject (so it is safely
                       ignored, never mispronounced) until a human replaces it
                       with a real katakana reading -- the suggested reading
                       is only a comment, to copy in after checking it.
  --auto-apply        (unattended) writes the *real* heuristic reading
                       straight to --auto-tsv, a separate, non-git-tracked
                       file, and rebuilds -- this is what claude-tts-speak's
                       CLAUDE_TTS_AUTO_DICT trigger runs so the dictionary
                       grows on its own, with nothing to maintain by hand.
                       Kept apart from user_dict_terms.tsv so an automatic
                       guess never lands in a file you might hand-edit or
                       commit; --build always merges both, curated entries
                       taking precedence over an auto one for the same word.

    python3 voicevox/import-candidates.py                    # preview
    python3 voicevox/import-candidates.py --write            # append candidates to TSV
    python3 voicevox/import-candidates.py --write --build    # then rebuild it
    python3 voicevox/import-candidates.py --auto-apply       # unattended: guess, write, rebuild

For --write (not --auto-apply), edit each new line's pronunciation column to
katakana and rebuild (or run ./install.sh, which rebuilds on its own).
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_TSV = os.path.join(HERE, "user_dict_terms.tsv")
DEFAULT_CANDIDATES = os.path.join(
    os.path.expanduser("~"), ".local/share/opencode-tts-speakd/unknown_words.txt")
DEFAULT_DICT = os.path.join(HERE, "..", "assets", "user_dict.json")
DEFAULT_AUTO_TSV = os.path.join(
    os.path.expanduser("~"), ".local/share/opencode-tts-speakd/auto_dict_terms.tsv")
TSV_FIELDS = ("surface", "pronunciation", "accent_type", "word_type", "priority")
# A word typed entirely in caps is read as an acronym, letter by letter, the
# way API / URL / SSH already sit in the dictionary -- a real word written in
# caps (README, OAuth) is rarer and still handled this way; fix it by hand.
LETTER_KATA = {
    "a": "エー", "b": "ビー", "c": "シー", "d": "ディー", "e": "エー",
    "f": "エフ", "g": "ジー", "h": "エイチ", "i": "アイ", "j": "ジェイ",
    "k": "ケイ", "l": "エル", "m": "エム", "n": "エヌ", "o": "オ", "p": "ピー",
    "q": "キュー", "r": "アー", "s": "エス", "t": "ティー", "u": "ユー",
    "v": "ヴェ", "w": "ダブル", "x": "エックス", "y": "ワイ", "z": "ゼット",
}

# Hepburn consonant+vowel -> katakana. si/ty/fu are Hepburn spellings.
CV = {
    "ka": "カ", "ki": "キ", "ku": "ク", "ke": "ケ", "ko": "コ",
    "sa": "サ", "si": "シ", "su": "ス", "se": "セ", "so": "ソ",
    "ta": "タ", "ti": "チ", "tu": "ツ", "te": "テ", "to": "ト",
    "na": "ナ", "ni": "ニ", "nu": "ヌ", "ne": "ネ", "no": "ノ",
    "ha": "ハ", "hi": "ヒ", "fu": "フ", "he": "ヘ", "ho": "ホ",
    "ma": "マ", "mi": "ミ", "mu": "ム", "me": "メ", "mo": "モ",
    "ya": "ヤ", "yu": "ユ", "yo": "ヨ",
    "ra": "ラ", "ri": "リ", "ru": "ル", "re": "レ", "ro": "ロ",
    "wa": "ワ", "wo": "ヲ",
    "ba": "バ", "bi": "ビ", "bu": "ブ", "be": "ベ", "bo": "ボ",
    "pa": "パ", "pi": "ピ", "pu": "プ", "pe": "ペ", "po": "ポ",
    "da": "ダ", "di": "ディ", "du": "ドゥ", "de": "デ", "do": "ド",
    "ga": "ガ", "gi": "ギ", "gu": "グ", "ge": "ゲ", "go": "ゴ",
    "za": "ザ", "ji": "ジ", "zu": "ズ", "ze": "ゼ", "zo": "ゾ",
    "cha": "チャ", "chu": "チュ", "che": "チェ", "cho": "チョ",
    "sha": "シャ", "shi": "シ", "shu": "シュ", "she": "シェ", "sho": "ショ",
    "ja": "ジャ", "ji": "ジ", "ju": "ジュ", "je": "ジェ", "jo": "ジョ",
    "fa": "ファ", "fi": "フィ", "fu": "フ", "fe": "フェ", "fo": "フォ",
    "tsu": "ツ", "ts": "ツ",
}
VOWELS = "aiueo"
# Shortest match first is wrong here, so we match 3 -> 2 -> 1 char explicitly.
# Digraph-consonant + vowel (cha, sha, fa, ...) live here alongside plain CV.
K3 = {"cha": "チャ", "chu": "チュ", "che": "チェ", "cho": "チョ",
      "sha": "シャ", "shu": "シュ", "she": "シェ", "sho": "ショ"}
K2 = {"ka": "カ", "ki": "キ", "ku": "ク", "ke": "ケ", "ko": "コ",
      "sa": "サ", "si": "シ", "su": "ス", "se": "セ", "so": "ソ",
      "ta": "タ", "ti": "チ", "tu": "ツ", "te": "テ", "to": "ト",
      "na": "ナ", "ni": "ニ", "nu": "ヌ", "ne": "ネ", "no": "ノ",
      "ha": "ハ", "hi": "ヒ", "fu": "フ", "he": "ヘ", "ho": "ホ",
      "ma": "マ", "mi": "ミ", "mu": "ム", "me": "メ", "mo": "モ",
      "ya": "ヤ", "yu": "ユ", "yo": "ヨ",
      "ra": "ラ", "ri": "リ", "ru": "ル", "re": "レ", "ro": "ロ",
      "wa": "ワ", "wo": "ヲ",
      "ba": "バ", "bi": "ビ", "bu": "ブ", "be": "ベ", "bo": "ボ",
      "pa": "パ", "pi": "ピ", "pu": "プ", "pe": "ペ", "po": "ポ",
      "da": "ダ", "di": "ディ", "du": "ドゥ", "de": "デ", "do": "ド",
      "ga": "ガ", "gi": "ギ", "gu": "グ", "ge": "ゲ", "go": "ゴ",
      "za": "ザ", "ji": "ジ", "zu": "ズ", "ze": "ゼ", "zo": "ゾ",
      "fa": "ファ", "fi": "フィ", "fe": "フェ", "fo": "フォ",
      "sh": "シ", "ch": "チ", "th": "ス", "ph": "フ", "wh": "ハ",
      "ts": "ツ"}
# A trailing unvoiced consonant holds (git -> ギット); a trailing voiced one
# is dropped (hub -> ハブ). Everything else maps to a sensible mora.
TRAILING = {"p": "ッ", "k": "ッ", "t": "ッ", "s": "ッ", "f": "ッ",
            "b": "", "d": "", "g": "", "z": "", "j": "",
            "r": "", "l": "", "n": "ン", "m": "ム", "w": "", "y": ""}
# A consonant that never got a vowel (rare: the "s" in "its", initials in
# acronyms handled elsewhere). Best effort; these words should be checked.
STRAY = {"b": "バ", "d": "ダ", "f": "フ", "g": "ガ", "h": "ハ", "j": "ジャ",
         "k": "カ", "l": "ラ", "m": "マ", "n": "ナ", "p": "パ", "q": "ク",
         "r": "ラ", "s": "ス", "t": "タ", "v": "バ", "w": "ワ", "x": "クス",
         "y": "イ", "z": "ザ"}


def surface(word):
    """Canonicalize a dictionary surface so comparison ignores fullwidth."""
    return unicodedata.normalize("NFKC", word).strip()


def _read_known(path):
    """Surfaces already handled, from a TSV or a compiled JSON dict."""
    if not path or not os.path.isfile(path):
        return set()
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return set()
    if path.endswith(".json"):
        try:
            data = json.loads(text)
        except ValueError:
            return set()
        if isinstance(data, dict):
            data = list(data.values())
        if isinstance(data, list):
            return {surface(e["surface"]) for e in data
                    if isinstance(e, dict) and e.get("surface")}
        return set()
    words = set()
    for line in text.splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "\t" in line:
            words.add(surface(line.split("\t")[0]))
    return words


def _split(word):
    """Split on camelCase and non-alnum boundaries, then lowercase.

    The capitals in a proper noun mark morpheme splits (Git+Hub, Lang+Chain)
    that lowercasing would hide, so romanize each piece and join.
    """
    s = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", word)
    s = re.sub(r"(?<=[A-Z])(?=[A-Z][a-z])", " ", s)
    s = re.sub(r"[^A-Za-z0-9]", " ", s)
    return [t.lower() for t in s.split() if t]


def _romanize(tok):
    """One lowercase token -> katakana, best-effort Hepburn."""
    out = []
    i, n = 0, len(tok)
    while i < n:
        c = tok[i]
        nxt = tok[i + 1] if i + 1 < n else ""
        tri = tok[i:i + 3]
        dig = tok[i:i + 2]
        if tri in K3:
            out.append(K3[tri])
            i += 3
            continue
        if dig in K2:
            out.append(K2[dig])
            i += 2
            continue
        # long vowel: doubled a/i/u/e/o, or ou/oo
        if c in VOWELS and nxt in VOWELS and (nxt == c or tri[1:] in ("ou", "oo")):
            out.append("ー")
            i += 2
            continue
        # r-controlled ending syllable (server -> サーバー): vowel+r at a
        # consonant or word boundary reads as one long mora.
        if c in "aeiou" and nxt == "r" and (i + 2 >= n or tok[i + 2] not in VOWELS):
            out.append("ー")
            i += 2
            continue
        # the n-mora is always ン in katakana
        if c == "n":
            out.append("ン")
            i += 1
            continue
        # a consonant cluster before a vowel holds the first (Git -> ギッ,
        # Dock -> ドッ): emit a small tsu and reprocess the onset.
        if (c not in VOWELS and nxt not in VOWELS and i + 2 < n
                and tok[i + 2] in VOWELS):
            out.append("ッ")
            i += 1
            continue
        # doubled consonant: first holds (bak -> バッ, app -> アッ)
        if nxt == c and c in "bdgjklmnprstz":
            out.append("ッ")
            i += 1
            continue
        # trailing consonant at end of token
        if i + 1 == n:
            out.append(TRAILING.get(c, ""))
            i += 1
            continue
        out.append(STRAY.get(c, ""))
        i += 1
    return "".join(out)


def suggest_reading(word):
    """A best-effort kana reading, shown to you -- NOT written into the file.

    Acronyms read letter-by-letter; other words use Hepburn per camelCase
    token. It is only a starting point: multi-syllable proper nouns are often
    wrong, and a wrong reading spoken aloud is worse than silence, so it never
    goes in the pronunciation column (which the build would accept and speak).
    """
    if word.isupper() and len(word) <= 12:
        return "".join(LETTER_KATA.get(c, c) for c in word.lower())
    return "".join(_romanize(t) for t in _split(word))


def read_candidates(path):
    words = []
    if not os.path.isfile(path):
        return words
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            w = line.strip()
            if w and w not in words:
                words.append(w)
    return words


def main():
    ap = argparse.ArgumentParser(__doc__)
    ap.add_argument("candidates", nargs="?", default=DEFAULT_CANDIDATES,
                    help="source file, one word per line (default: %(default)s)")
    ap.add_argument("-o", "--out", default=DEFAULT_TSV,
                    help="user_dict_terms.tsv to append to")
    ap.add_argument("-d", "--dict", default=DEFAULT_DICT,
                    help="compiled user_dict.json to dedupe against")
    ap.add_argument("--build", action="store_true",
                    help="rebuild the dictionary after writing")
    ap.add_argument("--write", action="store_true",
                    help="append to the TSV (default: preview only)")
    ap.add_argument("--force", action="store_true",
                    help="import words already present in the dictionary too")
    ap.add_argument("--auto-apply", action="store_true",
                    help="unattended mode: write real (not placeholder) "
                         "heuristic readings to --auto-tsv and rebuild -- "
                         "implies --write --build")
    ap.add_argument("--auto-tsv", default=DEFAULT_AUTO_TSV,
                    help="where --auto-apply writes (default: %(default)s)")
    ap.add_argument("--rebuild-only", action="store_true",
                    help="skip reading candidates entirely; just merge --out "
                         "and --auto-tsv and rebuild --dict. This is what "
                         "install.sh runs, so re-running it never discards "
                         "readings --auto-apply already learned")
    ap.add_argument("--shim", default=None,
                    help="opencode-tts-voicevox binary to rebuild with "
                         "(default: found on PATH, then ~/.local/bin)")
    args = ap.parse_args()
    if args.auto_apply:
        args.write = True
        args.build = True
    if args.rebuild_only:
        return rebuild([args.out, args.auto_tsv], args.dict, args.shim)

    words = read_candidates(args.candidates)
    if not words:
        print("no candidates to import")
        return 0

    target = args.auto_tsv if args.auto_apply else args.out
    known = (_read_known(args.out) | _read_known(args.dict)
             | _read_known(args.auto_tsv))
    pending = [w for w in words
               if (surface(w) not in known or args.force)]
    skipped = [w for w in words if surface(w) in known and not args.force]

    if args.auto_apply:
        # A word the heuristic romanizer has nothing to say about (e.g. a
        # bare consonant cluster) is left for a human via --write instead of
        # guessed badly.
        unusable = [w for w in pending if not suggest_reading(w)]
        pending = [w for w in pending if suggest_reading(w)]
        for w in unusable:
            print("skip %s (no automatic reading; needs a human)" % w)

    for w in pending:
        tag = "ADD " if args.write else "add "
        print("%s%s  (reading: %s)" % (tag, w, suggest_reading(w)))
    for w in skipped:
        print("skip %s (already in dictionary)" % w)

    if not pending:
        print("nothing new to import")
    elif not args.write:
        print("\n(silent; pass --write to update %s)" % target)

    if args.write and pending:
        try:
            os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
            with open(target, "a", encoding="utf-8") as fh:
                for w in pending:
                    if args.auto_apply:
                        # A real katakana reading straight away -- this file
                        # is never hand-edited, so there is no placeholder /
                        # "needs a human" step to protect.
                        fh.write("%s\t%s\t0\tPROPER_NOUN\t10  # auto\n"
                                 % (w, suggest_reading(w)))
                    else:
                        # Placeholder pronunciation (non-kana) fails the
                        # builder's validation, so an unfilled candidate is
                        # ignored rather than mispronounced. Swap in a real
                        # reading before rebuilding.
                        fh.write("%s\t%s\t0\tPROPER_NOUN\t10"
                                 "  # %s -- replace with a kana reading\n"
                                 % (w, w.lower(), suggest_reading(w)))
            print("\nwrote %d entr%s to %s"
                  % (len(pending), y(len(pending)), target))
        except OSError as exc:
            print("import-candidates: cannot write %s: %s" % (target, exc),
                  file=sys.stderr)
            return 1

    if args.write and args.build:
        return rebuild([args.out, args.auto_tsv], args.dict, args.shim)
    return 0


def rebuild(tsv_paths, dict_json, shim=None):
    """Compile one or more TSVs into the user dict, like install.sh does.

    --build-user-dict only takes a single TSV, so multiple files (the
    hand-curated one plus the auto-generated one) are merged into a temp file
    first. A surface already added from an earlier path in `tsv_paths` is
    skipped from any later one, so listing the curated file first means a
    hand-verified reading always wins over an auto-generated guess for the
    same word.
    """
    if isinstance(tsv_paths, str):
        tsv_paths = [tsv_paths]
    shim = shim or shutil.which("opencode-tts-voicevox") or os.path.join(
        os.path.expanduser("~"), ".local/bin/opencode-tts-voicevox")
    if not os.path.isfile(shim):
        print("import-candidates: cannot find opencode-tts-voicevox; "
              "skipping rebuild", file=sys.stderr)
        return 1

    seen = set()
    merged = []
    for path in tsv_paths:
        if not path or not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                raw = line.rstrip("\n")
                stripped = raw.strip()
                if not stripped or stripped.startswith("#") or "\t" not in stripped:
                    merged.append(raw)
                    continue
                s = surface(stripped.split("\t")[0])
                if s in seen:
                    continue
                seen.add(s)
                merged.append(raw)

    fd, tmp_path = tempfile.mkstemp(suffix=".tsv", prefix="opencode-tts-dict-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write("\n".join(merged) + "\n")
        try:
            proc = subprocess.run(
                [shim, "--build-user-dict", tmp_path, dict_json],
                capture_output=True, text=True)
        except OSError as exc:
            print("import-candidates: rebuild failed (%s)" % exc, file=sys.stderr)
            return 1
    finally:
        try:
            os.remove(tmp_path)
        except OSError:
            pass
    # The core lib prints a loud per-word validation ERROR (in Japanese) for
    # each placeholder reading; our own "opencode-tts-voicevox:" line reports
    # the same skip in plain form, so drop the core lib's noise.
    if proc.stderr:
        for line in proc.stderr.splitlines():
            if "voicevox_core::" not in line:
                sys.stderr.write(line + "\n")
    if proc.stdout:
        sys.stdout.write(proc.stdout)
    if proc.returncode != 0:
        print("import-candidates: rebuild failed (see above)")
        return proc.returncode
    print("rebuilt %s" % dict_json)
    return 0


def y(n):
    return "y" if n == 1 else "ies"


if __name__ == "__main__":
    sys.exit(main())
