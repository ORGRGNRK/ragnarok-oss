@echo off
REM heimdall-debug.bat — Windows CMD Launcher for Heimdall Terminal Pipeline & Error Debugger
setlocal
where python >nul 2>nul
if %ERRORLEVEL% equ 0 (
    python "%~dp0heimdall-debugger.py" %*
) else (
    where py >nul 2>nul
    if %ERRORLEVEL% equ 0 (
        py -3 "%~dp0heimdall-debugger.py" %*
    ) else (
        echo [Error] Python 3 not found in PATH. Please install Python from https://python.org or the Microsoft Store.
        exit /b 1
    )
)
endlocal
