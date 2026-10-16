# Makefile - builds play (the editor and player) on Linux, macOS and Windows
# with MinGW / MSYS2 / Cygwin's mingw gcc. (Windows with Visual Studio: make.bat.)
#
#   make                    a build (-O2)
#   make debug              -O0 -g
#   make release            -O3, NDEBUG
#   make tidy               removes what a build made
#   make SDL_DIR=/opt/sdl3  SDL3 from a folder of your own (its include/ and lib/)
#
# Needs SDL3 (3.2 or newer; the headers used are 3rd/SDL3's): Linux, your
# distro's libsdl3-dev or a build of your own; macOS, `brew install sdl3`;
# Windows, 3rd/SDL3/x64/SDL3.dll (linked directly, copied beside play.exe).
# Lua (minilua) and lite are in 3rd/, built in.

SRC     = play.c editor/editor.c
CC     ?= cc
OPT    ?= -O2
CFLAGS += -I3rd -I. -w
LIBS    = -lm

ifeq ($(OS),Windows_NT)                 # MinGW, MSYS2, Cygwin (x86_64-w64-mingw32-gcc)
  EXE    = play.exe
  SDL    = 3rd/SDL3/x64/SDL3.dll
  LIBS  += -lws2_32
  ifeq ($(CC),cc)
    CC   = gcc
  endif
else
  EXE    = play
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

$(EXE): $(SRC) $(wildcard editor/*.h) $(wildcard 3rd/lite/*.h) $(wildcard 3rd/minilua/*.h)
	$(CC) $(OPT) $(CFLAGS) $(SRC) -o $@ $(SDL) $(LIBS) $(LDFLAGS)
ifeq ($(OS),Windows_NT)
	cp -f 3rd/SDL3/x64/SDL3.dll .
endif

debug:
	$(MAKE) OPT="-O0 -g" -B
release:
	$(MAKE) OPT="-O3 -DNDEBUG" -B
tidy:
	rm -f play play.exe *.o *.obj *.pdb *.ilk SDL3.dll

.PHONY: all debug release tidy
