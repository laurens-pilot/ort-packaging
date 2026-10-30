$ErrorActionPreference = "Stop"
$failures = @()
Get-ChildItem (Join-Path $PSScriptRoot "*.ps1") | ForEach-Object {
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$parseErrors) | Out-Null
    $failures += $parseErrors
}
if ($failures.Count) {
    $failures | Format-List
    exit 1
}
