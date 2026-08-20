// SPDX-License-Identifier: MIT
//
// opencode-tts-voicevox: an edge-tts CLI lookalike backed by
// VOICEVOX CORE + a local voice model, so the opencode-tts plugin can run
// fully offline (no Microsoft endpoint).
//
// Accepts the same flags opencode-tts (dist/index.js runTts) passes:
//   --voice <v> --rate <r> --volume <p> --text <t> --write-media <path>
// --voice picks one of the characters in models/0.vvm -- Zundamon (the
// default), Shikoku Metan, Kasukabe Tsumugi, Amehare Hau -- by name, with an
// optional style: "metan", "metan:sexy", "ja-JP-MetanNeural", or a bare
// VOICEVOX style id. $VOICEVOX_VOICE overrides it, for callers that hardcode
// --voice. `--list-voices` prints the table.
// --rate "+25%" -> VOICEVOX speedScale 1.25; --volume "+0%" -> volumeScale 1.0.
//
// Assets are found in $VOICEVOX_DIR, falling back to a compile-time default
// (pass -DDEFAULT_VOICEVOX_DIR=/path/to/assets/voicevox) or ./assets/voicevox.
//
// Build (Linux):
//   gcc -O2 -std=c11 -DDEFAULT_VOICEVOX_DIR="/path/to/assets/voicevox"
//       -I <voicevox dir>/core/include -o opencode-tts-voicevox opencode-tts-voicevox.c -ldl
// Build (macOS): same without -ldl (dlopen lives in libSystem).

// Apple's headers hide non-POSIX declarations under a strict _POSIX_C_SOURCE,
// so only ask for POSIX.1-2008 where glibc needs it to expose strdup().
#ifndef __APPLE__
#define _POSIX_C_SOURCE 200809L
#endif

#include <stdint.h>

#include <ctype.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "voicevox_core.h"

// Shared-library suffix of the platform CORE was downloaded for; the Makefile
// passes the right one, this is just the Linux fallback for a bare compile.
#ifndef VOICEVOX_LIB_EXT
#define VOICEVOX_LIB_EXT "so"
#endif

// Ditto for the asset directory -- the Makefile always passes
// -DDEFAULT_VOICEVOX_DIR, this is only the fallback for a bare compile.
#ifndef DEFAULT_VOICEVOX_DIR
#define DEFAULT_VOICEVOX_DIR "assets/voicevox"
#endif

typedef void (*json_free_fn)(char*);
typedef void (*wav_free_fn)(uint8_t*);
typedef const char* (*err_msg_fn)(VoicevoxResultCode);

static int file_exists_dir(const char* dir) {
  char p[4096];
  snprintf(p, sizeof(p), "%s/core/lib/libvoicevox_core." VOICEVOX_LIB_EXT, dir);
  FILE* f = fopen(p, "rb");
  if (!f)
    return 0;
  fclose(f);
  return 1;
}

// Every style packed into models/0.vvm, each with the names --voice accepts
// for it. The first style listed for a character is that character's
// default -- ノーマル in every case.
typedef struct {
  const char* label;
  const char* aliases[4];  // NULL-terminated
  uint32_t id;
} Style;

typedef struct {
  const char* label;
  const char* aliases[4];  // NULL-terminated
  Style styles[5];         // a NULL label terminates
} Character;

static const Character CHARACTERS[] = {
    {"ずんだもん", {"zundamon", "zunda", "ずんだもん", NULL},
     {{"ノーマル", {"normal", "ノーマル", NULL}, 3},
      {"あまあま", {"amaama", "sweet", "あまあま", NULL}, 1},
      {"ツンツン", {"tsuntsun", "tsun", "ツンツン", NULL}, 7},
      {"セクシー", {"sexy", "セクシー", NULL}, 5},
      {NULL, {NULL}, 0}}},
    {"四国めたん", {"shikokumetan", "metan", "めたん", NULL},
     {{"ノーマル", {"normal", "ノーマル", NULL}, 2},
      {"あまあま", {"amaama", "sweet", "あまあま", NULL}, 0},
      {"ツンツン", {"tsuntsun", "tsun", "ツンツン", NULL}, 6},
      {"セクシー", {"sexy", "セクシー", NULL}, 4},
      {NULL, {NULL}, 0}}},
    {"春日部つむぎ", {"kasukabetsumugi", "tsumugi", "つむぎ", NULL},
     {{"ノーマル", {"normal", "ノーマル", NULL}, 8},
      {NULL, {NULL}, 0}}},
    {"雨晴はう", {"ameharehau", "hau", "はう", NULL},
     {{"ノーマル", {"normal", "ノーマル", NULL}, 10},
      {NULL, {NULL}, 0}}},
};

#define N_CHARACTERS (sizeof(CHARACTERS) / sizeof(CHARACTERS[0]))

static const VoicevoxStyleId DEFAULT_STYLE = 3;  // ずんだもん ノーマル

// Lowercase the ASCII, drop ASCII punctuation, keep every other byte (so a
// name written in Japanese survives intact). It is what makes the edge-tts
// spellings in existing configs work: "ja-JP-ZundamonNeural" normalizes to
// something the alias "zundamon" is a plain substring of.
static void normalize(const char* in, char* out, size_t n) {
  size_t o = 0;
  for (; *in && o + 1 < n; in++) {
    unsigned char c = (unsigned char)*in;
    if (c >= 0x80)
      out[o++] = (char)c;
    else if (isalnum(c))
      out[o++] = (char)tolower(c);
  }
  out[o] = '\0';
}

static int alias_match(const char* norm, const char* const* aliases) {
  for (; *aliases; aliases++)
    if (strstr(norm, *aliases))
      return 1;
  return 0;
}

// 1 if `voice` names something synthesizable, with *style set to it.
static int resolve_voice(const char* voice, VoicevoxStyleId* style) {
  if (!voice || !*voice)
    return 0;
  char norm[256];
  normalize(voice, norm, sizeof(norm));
  if (!*norm)
    return 0;

  // A bare number addresses styles this table does not know about, which is
  // the escape hatch if a future .vvm ships more of them.
  char* end;
  long id = strtol(norm, &end, 10);
  if (!*end && id >= 0) {
    *style = (VoicevoxStyleId)id;
    return 1;
  }

  for (size_t i = 0; i < N_CHARACTERS; i++) {
    const Character* c = &CHARACTERS[i];
    if (!alias_match(norm, c->aliases))
      continue;
    *style = c->styles[0].id;
    for (const Style* st = c->styles; st->label; st++) {
      if (alias_match(norm, st->aliases)) {
        *style = st->id;
        break;
      }
    }
    return 1;
  }
  return 0;
}

static void list_voices(void) {
  printf("--voice takes a character name, optionally a style after it\n"
         "(\"metan\", \"metan:sexy\", \"ja-JP-MetanNeural\"), or a style id.\n"
         "$VOICEVOX_VOICE overrides --voice.\n\n");
  for (size_t i = 0; i < N_CHARACTERS; i++) {
    const Character* c = &CHARACTERS[i];
    printf("%s / %s\n", c->label, c->aliases[0]);
    for (const Style* st = c->styles; st->label; st++)
      printf("  %2u  %s  %s:%s%s\n", (unsigned)st->id, st->label,
             c->aliases[0], st->aliases[0],
             st->id == DEFAULT_STYLE ? "   (default)" : "");
  }
}

static int set_json_number(char** jsp, const char* field, double v) {
  char* json = *jsp;
  char key[80];
  snprintf(key, sizeof(key), "\"%s\":", field);
  char* start = strstr(json, key);
  if (!start)
    return 0;
  start += strlen(key);
  char* end = start;
  while (*end && (isdigit((unsigned char)*end) || *end == '-' ||
                  *end == '+' || *end == '.' || *end == 'e' || *end == 'E'))
    end++;
  char tmpv[32];
  snprintf(tmpv, sizeof(tmpv), "%.6g", v);
  memmove(start + strlen(tmpv), end, strlen(end) + 1);
  memcpy(start, tmpv, strlen(tmpv));
  return 1;
}

// --build-user-dict <words.tsv> <out.json>: builds a VOICEVOX user
// dictionary from a flat word list and saves it as JSON, without touching
// onnxruntime or any voice model. OpenJtalk's own guesses are what usually
// turn tech jargon and acronyms into letter-by-letter spelling; this is the
// fix (see voicevox_open_jtalk_rc_use_user_dict() below, which loads the
// json this produces).
//
// TSV columns (tab-separated; blank lines and "#" comments skipped):
//   surface<TAB>pronunciation<TAB>accent_type[<TAB>word_type[<TAB>priority]]
//     surface       as it appears in text, e.g. "API"
//     pronunciation katakana reading, e.g. "エーピーアイ"
//     accent_type   mora index of the pitch drop (0 = heiban/flat -- a safe
//                   default when the real accent isn't known)
//     word_type     PROPER_NOUN (default) | COMMON_NOUN | VERB | ADJECTIVE |
//                   SUFFIX
//     priority      0-10, higher wins over OpenJtalk's own guess (default 10)
static int build_user_dict_mode(const char* core_lib, const char* tsv_path,
                                const char* json_path) {
  void* h = dlopen(core_lib, RTLD_NOW | RTLD_LOCAL);
  if (!h) {
    fprintf(stderr, "opencode-tts-voicevox: dlopen(%s): %s\n", core_lib,
            dlerror());
    return 1;
  }

  struct VoicevoxUserDict* (*p_new)(void) = NULL;
  struct VoicevoxUserDictWord (*p_make)(const char*, const char*,
                                        uintptr_t) = NULL;
  VoicevoxResultCode (*p_add)(const struct VoicevoxUserDict*,
                              const struct VoicevoxUserDictWord*,
                              uint8_t(*)[16]) = NULL;
  VoicevoxResultCode (*p_save)(const struct VoicevoxUserDict*,
                               const char*) = NULL;
  void (*p_delete)(struct VoicevoxUserDict*) = NULL;
  err_msg_fn p_err = NULL;

#define DNEED(sym, name)                                                    \
  do {                                                                      \
    void* _s = dlsym(h, name);                                              \
    if (!_s) {                                                              \
      fprintf(stderr, "opencode-tts-voicevox: missing " name "\n");         \
      return 1;                                                             \
    }                                                                       \
    *(void**)&(sym) = _s;                                                   \
  } while (0)

  DNEED(p_new, "voicevox_user_dict_new");
  DNEED(p_make, "voicevox_user_dict_word_make");
  DNEED(p_add, "voicevox_user_dict_add_word");
  DNEED(p_save, "voicevox_user_dict_save");
  DNEED(p_delete, "voicevox_user_dict_delete");
  p_err = (err_msg_fn)dlsym(h, "voicevox_error_result_to_message");
#undef DNEED

  FILE* fh = fopen(tsv_path, "r");
  if (!fh) {
    fprintf(stderr, "opencode-tts-voicevox: cannot open %s\n", tsv_path);
    return 1;
  }

  struct VoicevoxUserDict* dict = p_new();
  char line[1024];
  int added = 0, skipped = 0;
  while (fgets(line, sizeof(line), fh)) {
    char* nl = strpbrk(line, "\r\n");
    if (nl)
      *nl = '\0';
    if (!line[0] || line[0] == '#')
      continue;

    char* fields[5] = {0};
    int n = 0;
    char* save = NULL;
    for (char* tok = strtok_r(line, "\t", &save); tok && n < 5;
         tok = strtok_r(NULL, "\t", &save))
      fields[n++] = tok;
    if (n < 3) {
      fprintf(stderr, "opencode-tts-voicevox: skipping malformed line: %s\n",
              line);
      skipped++;
      continue;
    }

    uintptr_t accent = (uintptr_t)strtoul(fields[2], NULL, 10);
    struct VoicevoxUserDictWord word = p_make(fields[0], fields[1], accent);
    if (n >= 4) {
      if (!strcasecmp(fields[3], "COMMON_NOUN"))
        word.word_type = VOICEVOX_USER_DICT_WORD_TYPE_COMMON_NOUN;
      else if (!strcasecmp(fields[3], "VERB"))
        word.word_type = VOICEVOX_USER_DICT_WORD_TYPE_VERB;
      else if (!strcasecmp(fields[3], "ADJECTIVE"))
        word.word_type = VOICEVOX_USER_DICT_WORD_TYPE_ADJECTIVE;
      else if (!strcasecmp(fields[3], "SUFFIX"))
        word.word_type = VOICEVOX_USER_DICT_WORD_TYPE_SUFFIX;
      else
        word.word_type = VOICEVOX_USER_DICT_WORD_TYPE_PROPER_NOUN;
    }
    word.priority = n >= 5 ? (uint8_t)strtoul(fields[4], NULL, 10) : 10;

    uint8_t uuid[16];
    VoicevoxResultCode rc = p_add(dict, &word, &uuid);
    if (rc != VOICEVOX_RESULT_OK) {
      fprintf(stderr, "opencode-tts-voicevox: \"%s\": %s\n", fields[0],
              p_err ? p_err(rc) : "(no detail)");
      skipped++;
      continue;
    }
    added++;
  }
  fclose(fh);

  VoicevoxResultCode rc = p_save(dict, json_path);
  p_delete(dict);
  if (rc != VOICEVOX_RESULT_OK) {
    fprintf(stderr, "opencode-tts-voicevox: save %s: %s\n", json_path,
            p_err ? p_err(rc) : "(no detail)");
    return 1;
  }
  printf("opencode-tts-voicevox: wrote %s (%d words, %d skipped)\n",
         json_path, added, skipped);
  return 0;
}

int main(int argc, char** argv) {
  if (argc >= 4 && !strcmp(argv[1], "--build-user-dict")) {
    const char* dir = getenv("VOICEVOX_DIR");
    if (!dir || !*dir)
      dir = file_exists_dir(DEFAULT_VOICEVOX_DIR) ? DEFAULT_VOICEVOX_DIR
                                                   : "assets/voicevox";
    char core_lib[4096];
    snprintf(core_lib, sizeof(core_lib),
             "%s/core/lib/libvoicevox_core." VOICEVOX_LIB_EXT, dir);
    return build_user_dict_mode(core_lib, argv[2], argv[3]);
  }

  const char* text = NULL;
  const char* out_path = NULL;
  const char* voice = NULL;
  double rate_pct = 0.0;
  double volume_pct = 0.0;

  for (int i = 1; i < argc; i++) {
    const char* a = argv[i];
    const char* next = i + 1 < argc ? argv[i + 1] : NULL;
    if (!strcmp(a, "--text") && next) {
      text = next;
      i++;
    } else if (!strcmp(a, "--write-media") && next) {
      out_path = next;
      i++;
    } else if (!strcmp(a, "--rate") && next) {
      if (next[0] == '+' || next[0] == '-' || isdigit((unsigned char)next[0]))
        rate_pct = atof(next);
      i++;
    } else if (!strcmp(a, "--volume") && next) {
      if (next[0] == '+' || next[0] == '-' || isdigit((unsigned char)next[0]))
        volume_pct = atof(next);
      i++;
    } else if (!strcmp(a, "--voice") && next) {
      voice = next;
      i++;
    } else if (!strcmp(a, "--list-voices")) {
      list_voices();
      return 0;
    }
  }

  // The environment wins: callers that hardcode --voice (claude-tts-speak, an
  // opencode-tts config you would rather not edit) still leave this open.
  VoicevoxStyleId style = DEFAULT_STYLE;
  if (!resolve_voice(getenv("VOICEVOX_VOICE"), &style) &&
      voice && *voice && !resolve_voice(voice, &style)) {
    // An edge-tts voice name for some other engine ("en-US-AvaNeural") is not
    // an error -- the dispatcher hands us whatever the plugin config says.
    fprintf(stderr, "opencode-tts-voicevox: unknown voice \"%s\", using %s\n",
            voice, CHARACTERS[0].label);
  }

  if (!text || !*text) {
    fprintf(stderr, "opencode-tts-voicevox: no --text\n");
    return 2;
  }
  if (!out_path) {
    fprintf(stderr, "opencode-tts-voicevox: no --write-media\n");
    return 2;
  }

  const char* dir = getenv("VOICEVOX_DIR");
  if (!dir || !*dir)
    dir = DEFAULT_VOICEVOX_DIR;
  if (!file_exists_dir(dir))
    dir = "assets/voicevox";

  char core_lib[4096];
  snprintf(core_lib, sizeof(core_lib),
           "%s/core/lib/libvoicevox_core." VOICEVOX_LIB_EXT, dir);
  void* h = dlopen(core_lib, RTLD_NOW | RTLD_LOCAL);
  if (!h) {
    fprintf(stderr, "opencode-tts-voicevox: dlopen(%s): %s\n", core_lib,
            dlerror());
    return 1;
  }

#define NEED(sym, name)                                     \
  do {                                                      \
    void* _s = dlsym(h, name);                              \
    if (!_s) {                                              \
      fprintf(stderr, "opencode-tts-voicevox: missing " name "\n"); \
      return 1;                                             \
    }                                                       \
    *(void**)&(sym) = _s;                                   \
  } while (0)

  VoicevoxLoadOnnxruntimeOptions (*p_ort_opts)(void) = NULL;
  VoicevoxResultCode (*p_onnx)(VoicevoxLoadOnnxruntimeOptions,
                               const VoicevoxOnnxruntime**) = NULL;
  VoicevoxResultCode (*p_oj)(const char*, OpenJtalkRc**) = NULL;
  VoicevoxResultCode (*p_new)(const VoicevoxOnnxruntime*,
                              const OpenJtalkRc*, VoicevoxInitializeOptions,
                              VoicevoxSynthesizer**) = NULL;
  VoicevoxInitializeOptions (*p_init_opts)(void) = NULL;
  VoicevoxResultCode (*p_mopen)(const char*, VoicevoxVoiceModelFile**) = NULL;
  VoicevoxResultCode (*p_mload)(const VoicevoxSynthesizer*,
                                const VoicevoxVoiceModelFile*,
                                VoicevoxLoadVoiceModelOptions) = NULL;
  VoicevoxLoadVoiceModelOptions (*p_mlopts)(void) = NULL;
  VoicevoxResultCode (*p_query)(const VoicevoxSynthesizer*, const char*,
                                VoicevoxStyleId, char**) = NULL;
  VoicevoxResultCode (*p_synth)(const VoicevoxSynthesizer*, const char*,
                                VoicevoxStyleId, VoicevoxSynthesisOptions,
                                uintptr_t*, uint8_t**) = NULL;
  VoicevoxSynthesisOptions (*p_sopts)(void) = NULL;
  json_free_fn p_jfree = NULL;
  wav_free_fn p_wfree = NULL;
  err_msg_fn p_err = NULL;

  NEED(p_ort_opts, "voicevox_make_default_load_onnxruntime_options");
  NEED(p_onnx, "voicevox_onnxruntime_load_once");
  NEED(p_oj, "voicevox_open_jtalk_rc_new");
  NEED(p_new, "voicevox_synthesizer_new");
  NEED(p_init_opts, "voicevox_make_default_initialize_options");
  NEED(p_mopen, "voicevox_voice_model_file_open");
  NEED(p_mload, "voicevox_synthesizer_load_voice_model");
  NEED(p_mlopts, "voicevox_make_default_load_voice_model_options");
  NEED(p_query, "voicevox_synthesizer_create_audio_query");
  NEED(p_synth, "voicevox_synthesizer_synthesis");
  NEED(p_sopts, "voicevox_make_default_synthesis_options");
  NEED(p_jfree, "voicevox_json_free");
  NEED(p_wfree, "voicevox_wav_free");
  p_err = (err_msg_fn)dlsym(h, "voicevox_error_result_to_message");

#define CHECK(code, what)                                   \
  do {                                                      \
    if (code != VOICEVOX_RESULT_OK) {                       \
      fprintf(stderr, "opencode-tts-voicevox: %s: %s\n",    \
              what, p_err ? p_err(code) : "(no detail)");   \
      return 1;                                             \
    }                                                       \
  } while (0)

  char buf[4096];
  snprintf(buf, sizeof(buf),
           "%s/onnxruntime/lib/libvoicevox_onnxruntime." VOICEVOX_LIB_EXT, dir);
  VoicevoxLoadOnnxruntimeOptions ort = p_ort_opts();
  ort.filename = buf;
  const VoicevoxOnnxruntime* ortc;
  CHECK(p_onnx(ort, &ortc), "onnxruntime load");

  snprintf(buf, sizeof(buf), "%s/dict/open_jtalk_dic_utf_8-1.11", dir);
  OpenJtalkRc* oj;
  CHECK(p_oj(buf, &oj), "open jtalk load");

  // Optional: a user dictionary (see --build-user-dict) fixes words OpenJtalk
  // otherwise mispronounces or spells out letter-by-letter -- tech jargon,
  // acronyms, anything not in its base dictionary. Soft-fail on any problem
  // here: synthesis without the extra readings still works, and a stale or
  // half-written dict file must never take the whole CLI down.
  const char* user_dict_path = getenv("VOICEVOX_USER_DICT");
  char user_dict_buf[4096];
  if (!user_dict_path || !*user_dict_path) {
    snprintf(user_dict_buf, sizeof(user_dict_buf), "%s/user_dict.json", dir);
    user_dict_path = user_dict_buf;
  }
  FILE* udf = fopen(user_dict_path, "rb");
  if (udf) {
    fclose(udf);
    struct VoicevoxUserDict* (*p_ud_new)(void) = NULL;
    VoicevoxResultCode (*p_ud_load)(const struct VoicevoxUserDict*,
                                    const char*) = NULL;
    VoicevoxResultCode (*p_ud_use)(const struct OpenJtalkRc*,
                                   const struct VoicevoxUserDict*) = NULL;
    void* s_new = dlsym(h, "voicevox_user_dict_new");
    void* s_load = dlsym(h, "voicevox_user_dict_load");
    void* s_use = dlsym(h, "voicevox_open_jtalk_rc_use_user_dict");
    if (s_new && s_load && s_use) {
      *(void**)&p_ud_new = s_new;
      *(void**)&p_ud_load = s_load;
      *(void**)&p_ud_use = s_use;
      struct VoicevoxUserDict* ud = p_ud_new();
      VoicevoxResultCode rc = p_ud_load(ud, user_dict_path);
      if (rc == VOICEVOX_RESULT_OK)
        rc = p_ud_use(oj, ud);
      if (rc != VOICEVOX_RESULT_OK)
        fprintf(stderr, "opencode-tts-voicevox: user dict %s: %s\n",
                user_dict_path, p_err ? p_err(rc) : "(no detail)");
      // `ud` is intentionally leaked, not deleted: voicevox_open_jtalk_rc_use_user_dict
      // keeps referring to it, and this process is a one-shot CLI that is
      // about to exit anyway.
    } else {
      fprintf(stderr, "opencode-tts-voicevox: this voicevox_core build has "
                      "no user-dict support; ignoring %s\n", user_dict_path);
    }
  }

  VoicevoxInitializeOptions io = p_init_opts();
  io.acceleration_mode = VOICEVOX_ACCELERATION_MODE_CPU;
  VoicevoxSynthesizer* s;
  CHECK(p_new(ortc, oj, io, &s), "synthesizer_new");

  snprintf(buf, sizeof(buf), "%s/models/0.vvm", dir);
  VoicevoxVoiceModelFile* mf;
  CHECK(p_mopen(buf, &mf), "voice model open");
  CHECK(p_mload(s, mf, p_mlopts()), "voice model load");

  char* qtmp;
  CHECK(p_query(s, text, style, &qtmp), "audio query");
  char* q = strdup(qtmp);
  p_jfree(qtmp);

  double speed = 1.0 + rate_pct / 100.0;
  if (speed < 0.25) speed = 0.25;
  double volume = 1.0 + volume_pct / 100.0;
  if (volume < 0.05) volume = 0.05;

  set_json_number(&q, "speedScale", speed);
  set_json_number(&q, "volumeScale", volume);
  set_json_number(&q, "intonationScale", 1.0);

  uintptr_t wlen = 0;
  uint8_t* wav = NULL;
  CHECK(p_synth(s, q, style, p_sopts(), &wlen, &wav), "synthesis");

  FILE* f = fopen(out_path, "wb");
  if (!f) {
    fprintf(stderr, "opencode-tts-voicevox: cannot open %s\n", out_path);
    return 1;
  }
  if (wlen && wav)
    fwrite(wav, 1, wlen, f);
  fclose(f);
  free(q);
  p_wfree(wav);
  return 0;
}
