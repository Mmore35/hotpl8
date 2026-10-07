@echo off
rem The launcher of an installation that updates itself. The reader beside it is asked first,
rem in the words typed after hotpl8: it finds the release in force and has that release's own
rem reader answer. It ends with 0 for an answer and 1 for a refusal; any other status means
rem the words are not a request of the reader's, and launch.ps1 starts PowerShell with them.
rem cmd comes back to this file by position after every line, so the installed copy is never
rem given other text: see docs/install.md, "The launcher".
if not exist "%~dp0hotpl8-native.exe" goto powershell
"%~dp0hotpl8-native.exe" user %*
if errorlevel 2 goto powershell
if not errorlevel 0 goto powershell
exit /b %errorlevel%
:powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" -Entry hotpl8 %*
exit /b %errorlevel%
