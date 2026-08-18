# opencode-tts-voicevox: build the edge-tts CLI shim that speaks via VOICEVOX.
#
# Required: the path to a directory that looks like `assets/voicevox`, i.e.
#   <VOICEVOX_DIR>/core/include/voicevox_core.h
#   <VOICEVOX_DIR>/core/lib/libvoicevox_core.<so|dylib>
#   <VOICEVOX_DIR>/onnxruntime/lib/libvoicevox_onnxruntime.<so|dylib>
#   <VOICEVOX_DIR>/dict/open_jtalk_dic_utf_8-1.11
#   <VOICEVOX_DIR>/models/<one or more>.vvm
#
# The header and the baked-in default asset dir must point at the same place:
#
#   make VOICEVOX_DIR=/path/to/assets/voicevox
#   make VOICEVOX_DIR=/path/to/assets/voicevox PREFIX=~/.local   # install to ~/.local/bin
#   VOICEVOX_DIR=/path/to/assets/voicevox make install           # same, in one step

VOICEVOX_DIR ?= assets/voicevox
CC          ?= cc
CFLAGS      ?= -O2 -std=c11 -Wall -Wextra
PREFIX      ?= /usr/local

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  # macOS: dlopen() lives in libSystem and there is no libdl to link against.
  LIB_EXT := dylib
  DL_LIBS :=
else
  LIB_EXT := so
  DL_LIBS := -ldl
endif

# `$(VOICEVOX_DIR)` must be a valid C string literal, so wrap it in escaped
# quotes — the shell has to pass them through to cc, not strip them.
DEFAULT_DIR := -DDEFAULT_VOICEVOX_DIR=\"$(VOICEVOX_DIR)\"
LIB_EXT_DEF := -DVOICEVOX_LIB_EXT=\"$(LIB_EXT)\"
INCLUDE     := -I$(VOICEVOX_DIR)/core/include

TARGET := opencode-tts-voicevox

$(TARGET): opencode-tts-voicevox.c
	$(CC) $(CFLAGS) $(DEFAULT_DIR) $(LIB_EXT_DEF) $(INCLUDE) -o $@ $< $(DL_LIBS)

.PHONY: install clean
install: $(TARGET)
	mkdir -p $(PREFIX)/bin
	cp $(TARGET) $(PREFIX)/bin/$(TARGET)

clean:
	rm -f $(TARGET)
