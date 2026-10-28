@echo off
REM Finds the Flutter project (the folder with pubspec.yaml) under this
REM folder by itself, then runs it in Chrome on a fixed port (5000), so
REM Chrome remembers the location permission between runs.
REM
REM Put this file in the project folder (or any folder above it) and
REM double-click it. Extra options are passed on, e.g.:  run_app -d emulator-5554

setlocal
set "APPDIR="

if exist "%~dp0pubspec.yaml" set "APPDIR=%~dp0"
if not defined APPDIR if exist "%~dp0app\pubspec.yaml" set "APPDIR=%~dp0app\"

if not defined APPDIR (
    for /f "delims=" %%F in ('dir /s /b "%~dp0pubspec.yaml" 2^>nul ^| findstr /v /i "\\build\\ \\.dart_tool\\ \\ephemeral\\ \\.pub-cache\\"') do (
        if not defined APPDIR set "APPDIR=%%~dpF"
    )
)

if not defined APPDIR (
    echo Could not find pubspec.yaml under %~dp0
    echo Put run_app.bat in the MicroLink project folder.
    pause
    exit /b 1
)

echo Found Flutter project: %APPDIR%
cd /d "%APPDIR%"

call flutter pub get
if "%~1"=="" (
    call flutter run -d chrome --web-port=5000
) else (
    call flutter run %*
)
pause
