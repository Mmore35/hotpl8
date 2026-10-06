@echo off
rem The compiled reader is asked first, in the words typed after hotpl8. It ends with 0 for an
rem answer and 1 for a refusal; any other status means the words are not a request of its
rem own, and PowerShell is started with the same words.
rem cmd comes back to this file by position after every line, so a copy that sessions are
rem started from is never given other text: see docs/install.md, "The launcher".
if not exist "%~dp0bin\windows\hotpl8-native.exe" goto powershell
"%~dp0bin\windows\hotpl8-native.exe" user %*
if errorlevel 2 goto powershell
if not errorlevel 0 goto powershell
exit /b %errorlevel%
:powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0hotpl8.ps1" %*
exit /b %errorlevel%
