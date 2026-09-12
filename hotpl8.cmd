@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0hotpl8.ps1" %*
exit /b %errorlevel%
