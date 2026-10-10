@echo off
rem The compiled reader is asked first, in the words typed after hotpl8. It ends with 0 for an
rem answer and 1 for a refusal; any other status means the words are not a request of its
rem own, and PowerShell is started with the same words.
rem PowerShell is named by its whole path. cmd looks for a bare name in the current directory
rem before anywhere else, so a file called powershell in a folder someone works in would be
rem what ran. Without SystemRoot that path would start at the current drive, so nothing runs.
rem cmd comes back to this file by position after every line, so a copy that sessions are
rem started from is never given other text: see docs/install.md, "The launcher".
rem hotpl8.cmd beside this file is the one line that hands over to it.
if not exist "%~dp0bin\windows\hotpl8-native.exe" goto powershell
"%~dp0bin\windows\hotpl8-native.exe" user %*
if errorlevel 2 goto powershell
if not errorlevel 0 goto powershell
exit /b %errorlevel%
:powershell
if not defined SystemRoot goto nowhere
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0hotpl8.ps1" %*
exit /b %errorlevel%
:nowhere
echo HotPl8: SystemRoot is not set, so Windows PowerShell cannot be found.>&2
exit /b 1
