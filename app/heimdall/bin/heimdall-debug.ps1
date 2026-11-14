# heimdall-debug.ps1 — Windows PowerShell Launcher for Heimdall Terminal Pipeline & Error Debugger
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PyScript = Join-Path $ScriptDir "heimdall-debugger.py"

if (Get-Command python -ErrorAction SilentlyContinue) {
    & python $PyScript $args
} elseif (Get-Command py -ErrorAction SilentlyContinue) {
    & py -3 $PyScript $args
} else {
    Write-Error "[Error] Python 3 not found in PATH. Please install Python 3."
    exit 1
}
