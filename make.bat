@cd /d "%~dp0"
@if     "%1"=="tidy"    for /D /R %%i in (.trash) do @if exist "%%i" rd /q /s "%%i"
@if     "%1"=="tidy"    for /R %%i in (saves\*.sav;*.log.txt;*.workspace.lua;*.preferences.lua) do del /q "%%i"
@if     "%1"=="tidy"    del /Q *.exe *.obj *.pdb *.ilk *.dll >nul 2>nul & exit /b
@if     "%1"=="release" %0 /Ox /Oy /MT /DNDEBUG /arch:AVX /GL /GF

@rem Detect platform target (x86, x64 or arm64). We'll use the Developer Prompt's if we're in one, else this machine's
@set ARCH=%VSCMD_ARG_TGT_ARCH%
@if "%ARCH%"=="" set ARCH=%PROCESSOR_ARCHITECTURE%
@if defined PROCESSOR_ARCHITEW6432 if "%VSCMD_ARG_TGT_ARCH%"=="" set ARCH=%PROCESSOR_ARCHITEW6432%
@if /i "%ARCH%"=="AMD64" set ARCH=x64
@if /i "%ARCH%"=="ARM64" set ARCH=arm64

@rem Find Visual Studio (via vswhere, which is shipped with it) and set it up for that target
@where cl >nul 2>nul || (
  for /f "usebackq delims=" %%v in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -prerelease -property installationPath`) do @call "%%v\VC\Auxiliary\Build\vcvarsall.bat" %ARCH% >nul
  @where cl >nul 2>nul || (echo no Visual Studio C++ tools found & pause & exit /b 1)
)

@rem @todo: clang and gcc

@if not exist "*.dll"   copy editor\3rd\sdl3\%ARCH%\*.dll /y >nul
cl %* replay.c editor\editor.c -Ieditor\3rd -I. editor\3rd\SDL3\%ARCH%\SDL3.lib /nologo /MP
