@echo off
rem heaphjobs one-click installer and updater for HorizonXI (Ashita v4).
rem Fetches the installer script from the repo, then runs it. Run again any time to update.
setlocal
set "PS=%TEMP%\heaphjobs-install.ps1"
echo.
echo   Heaph Point Board, in game: installer
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/lost-rabbit/heaphjobs/main/install.ps1' -OutFile '%PS%'"
if errorlevel 1 (
    echo Could not download the installer script. Check your connection and try again.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS%"
del "%PS%" >nul 2>&1
echo.
pause
