@cd /d "%~dp0"
@if     "%1"=="tidy"    for /R %%i in (saves\*.sav;*.log.txt;*.workspace.lua) do del /q %%i
@if     "%1"=="tidy"    del /Q *.exe *.obj *.pdb *.ilk *.dll >nul 2>nul & exit /b
@if     "%1"=="release" %0 /Ox /Oy /MT /DNDEBUG /arch:AVX /GL /GF
@if not exist "*.dll"   copy 3rd\sdl3\x64\*.dll /y >nul
cl %* play.c editor\editor.c -I3rd -I. 3rd\SDL3\x64\SDL3.lib /nologo /MP
