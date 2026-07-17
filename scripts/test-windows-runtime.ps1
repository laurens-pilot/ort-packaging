$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$versions = @{}
Get-Content (Join-Path $RepoRoot "versions.env") | ForEach-Object {
    if ($_ -match '^([^#=]+)=(.*)$') { $versions[$Matches[1]] = $Matches[2] }
}

$target = if ($args.Count -gt 0) { $args[0] } else { "" }
if ($target -notin @("windows-x64", "windows-arm64")) {
    throw "usage: test-windows-runtime.ps1 <windows-x64|windows-arm64>"
}

$ortSource = if ($env:ORT_SOURCE_DIR) { $env:ORT_SOURCE_DIR } else { Join-Path $RepoRoot "onnxruntime" }
$buildRoot = if ($env:BUILD_ROOT) { $env:BUILD_ROOT } else { Join-Path $RepoRoot "build" }
$distRoot = if ($env:DIST_ROOT) { $env:DIST_ROOT } else { Join-Path $RepoRoot "dist" }
$packageDir = Join-Path $distRoot "$target/package"
$testBuildDir = Join-Path $buildRoot "$target-runtime-smoke"
$headers = Join-Path $ortSource "include/onnxruntime/core/session"
$model = Join-Path $ortSource "onnxruntime/test/testdata/mul_1.onnx"
$core = Join-Path $packageDir "onnxruntime.dll"
$plugin = Join-Path $packageDir "onnxruntime_providers_webgpu.dll"
foreach ($required in @($packageDir, $headers, $model, $core, $plugin)) {
    if (-not (Test-Path $required)) { throw "missing runtime smoke-test input: $required" }
}

Remove-Item $testBuildDir -Recurse -Force -ErrorAction SilentlyContinue
$architecture = if ($target -eq "windows-arm64") { "ARM64" } else { "x64" }
cmake -S (Join-Path $RepoRoot "tests") -B $testBuildDir `
    -G "Visual Studio 17 2022" `
    -A $architecture `
    -D "ORT_INCLUDE_DIR=$headers"
if ($LASTEXITCODE -ne 0) { throw "failed to configure the Windows runtime smoke test" }
cmake --build $testBuildDir --config Release --parallel
if ($LASTEXITCODE -ne 0) { throw "failed to build the Windows runtime smoke test" }

$testExecutable = Join-Path $testBuildDir "Release/runtime-smoke.exe"
if (-not (Test-Path $testExecutable)) { throw "missing runtime smoke-test executable: $testExecutable" }
Push-Location $packageDir
try {
    & $testExecutable $core $plugin $model "0" "D3D12"
    if ($LASTEXITCODE -ne 0) { throw "Windows runtime smoke test failed" }
} finally {
    Pop-Location
}
