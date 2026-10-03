@echo off
set "REPO_ROOT=%~dp0..\..\.."
cd /d "%REPO_ROOT%"
echo ========================================================
echo Running Fleet Elevated Tests...
echo ========================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%REPO_ROOT%\tests\platform\windows\elevated-runner.ps1"
echo.
echo ========================================================
echo Merging test results via tests\platform\windows\run.ps1...
echo ========================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%REPO_ROOT%\tests\platform\windows\run.ps1"
echo.
pause
