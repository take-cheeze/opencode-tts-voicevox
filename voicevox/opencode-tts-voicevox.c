// SPDX-License-Identifier: MIT
//
// opencode-tts-voicevox: an edge-tts CLI lookalike backed by
// VOICEVOX CORE + a local Zundamon voice model, so the opencode-tts
// plugin can run fully offline (no Microsoft endpoint).
//
// Accepts the same flags opencode-tts (dist/index.js runTts) passes:
//   --voice <v> --rate <r> --volume <p> --text <t> --write-media <path>
// --voice is accepted and ignored (the only model loaded is Zundamon's).
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

#include "voicevox_core.h"

// Shared-library suffix of the platform CORE was downloaded for; the Makefile
// passes the right one, this is just the Linux fallback for a bare compile.
#ifndef VOICEVOX_LIB_EXT
#define VOICEVOX_LIB_EXT "so"
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

int main(int argc, char** argv) {
  const char* text = NULL;
  const char* out_path = NULL;
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
    }
    // --voice: accepted and ignored (single loaded model).
  }

  if (!text || !*text) {
    fprintf(stderr, "opencode-tts-voicevox: no --text\n");
    return 2;
  }
  if (!out_path) {
    fprintf(stderr, "opencode-tts-voicevox: no --write-media\n");
    return 2;
  }

#ifndef DEFAULT_VOICEVOX_DIR
#define DEFAULT_VOICEVOX_DIR "assets/voicevox"
#endif
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

  VoicevoxInitializeOptions io = p_init_opts();
  io.acceleration_mode = VOICEVOX_ACCELERATION_MODE_CPU;
  VoicevoxSynthesizer* s;
  CHECK(p_new(ortc, oj, io, &s), "synthesizer_new");

  snprintf(buf, sizeof(buf), "%s/models/0.vvm", dir);
  VoicevoxVoiceModelFile* mf;
  CHECK(p_mopen(buf, &mf), "voice model open");
  CHECK(p_mload(s, mf, p_mlopts()), "voice model load");

  VoicevoxStyleId style = 3;  // Zundamon normal
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
