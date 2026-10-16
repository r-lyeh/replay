# Makefile - builds replay (the editor and player) on Linux, macOS and Windows
# with MinGW / MSYS2 / Cygwin's mingw gcc. (Windows with Visual Studio: make.bat.)
#
#   make                    a build (-O2)
#   make debug              -O0 -g
#   make release            -O3, NDEBUG
#   make test               runs every test suite (runtime/tests/run.lua, on a copy;
#                           LUA=luajit picks the interpreter)
#   make tidy               removes what a build made, and the temporaries in
#                           every folder (.workspace.lua, .log.txt, .trash/, saves/*.sav)
#   make SDL_DIR=/opt/sdl3  SDL3 from a folder of your own (its include/ and lib/)
#
# Needs SDL3 (3.2 or newer; the headers used are editor/3rd/SDL3's): Linux, your
# distro's libsdl3-dev or a build of your own; macOS, `brew install sdl3`;
# Windows, editor/3rd/SDL3/x64/SDL3.dll (linked directly, copied beside replay.exe).
# Lua (minilua) and lite are in editor/3rd/, built in.

SRC     = replay.c editor/editor.c
CC     ?= cc
OPT    ?= -O2
CFLAGS += -Ieditor/3rd -I. -w
LIBS    = -lm

ifeq ($(OS),Windows_NT)                 # MinGW, MSYS2, Cygwin (x86_64-w64-mingw32-gcc)
  EXE    = replay.exe
  SDL    = editor/3rd/SDL3/x64/SDL3.dll
  LIBS  += -lws2_32
  ifeq ($(CC),cc)
    CC   = gcc
  endif
else
  EXE    = replay
  UNAME := $(shell uname -s)
  ifneq ($(SDL_DIR),)
    SDL  = -L$(SDL_DIR)/lib -lSDL3 -Wl,-rpath,$(SDL_DIR)/lib
  else
    SDL  = $(shell pkg-config --libs sdl3 2>/dev/null || echo -lSDL3)
  endif
  ifeq ($(UNAME),Linux)
    LIBS += -ldl -lpthread
  endif
endif

all: $(EXE)

$(EXE): $(SRC) $(wildcard editor/*.h) $(wildcard editor/3rd/lite/*.h) $(wildcard editor/3rd/minilua/*.h)
	$(CC) $(OPT) $(CFLAGS) $(SRC) -o $@ $(SDL) $(LIBS) $(LDFLAGS)
ifeq ($(OS),Windows_NT)
	cp -f editor/3rd/SDL3/x64/SDL3.dll .
endif

LUA    ?= lua
test: $(EXE)
	$(LUA) runtime/tests/run.lua --exe $(EXE)

debug:
	$(MAKE) OPT="-O0 -g" -B
release:
	$(MAKE) OPT="-O3 -DNDEBUG" -B
tidy:                                   # (and every folder's temporaries: lite's workspaces, logs, the trash, savegames)
	rm -f replay replay.exe play play.exe *.o *.obj *.pdb *.ilk SDL3.dll
	find . \( -name '.workspace.lua' -o -name '.lite_workspace.lua' -o -name '.log.txt' -o -path '*/saves/*.sav' \) -type f -exec rm -f {} +
	find . -name '.trash' -type d -prune -exec rm -rf {} +

.PHONY: all debug release tidy test
