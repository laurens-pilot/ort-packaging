$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot

$target = if ($args.Count -gt 0) { $args[0] } else { "" }
if ($target -notin @("windows-x64", "windows-arm64")) {
    throw "usage: test-windows-runtime.ps1 <windows-x64|windows-arm64>"
}
$cmakeGenerator = if ($env:CMAKE_GENERATOR) { $env:CMAKE_GENERATOR } else { "Visual Studio 17 2022" }

$ortSource = if ($env:ORT_SOURCE_DIR) { $env:ORT_SOURCE_DIR } else { Join-Path $RepoRoot "onnxruntime" }
$buildRoot = if ($env:BUILD_ROOT) { $env:BUILD_ROOT } else { Join-Path $RepoRoot "build" }
$distRoot = if ($env:DIST_ROOT) { $env:DIST_ROOT } else { Join-Path $RepoRoot "dist" }
$packageDir = Join-Path $distRoot "$target/runtime-test"
$asset = Join-Path $distRoot "$target/onnxruntime-webgpu-$target-$($env:ORT_VERSION)-r$($env:PACKAGE_REVISION).zip"
Remove-Item $packageDir -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -Path $asset -DestinationPath $packageDir
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
    -G $cmakeGenerator `
    -A $architecture `
    -D "ORT_INCLUDE_DIR=$headers"
if ($LASTEXITCODE -ne 0) { throw "failed to configure the Windows runtime smoke test" }
cmake --build $testBuildDir --config Release --parallel
if ($LASTEXITCODE -ne 0) { throw "failed to build the Windows runtime smoke test" }

$testExecutable = Join-Path $testBuildDir "Release/runtime-smoke.exe"
if (-not (Test-Path $testExecutable)) { throw "missing runtime smoke-test executable: $testExecutable" }
Push-Location $packageDir
try {
    & $testExecutable $core $plugin $model $(if ($env:REQUIRE_WEBGPU -eq "1") { "1" } else { "0" }) "D3D12" | Tee-Object -FilePath (Join-Path $distRoot "$target/smoke.log")
    if ($LASTEXITCODE -ne 0) { throw "Windows runtime smoke test failed" }
} finally {
    Pop-Location
}

python (Join-Path $RepoRoot "scripts/release.py") record $asset --log (Join-Path $distRoot "$target/smoke.log")
if ($LASTEXITCODE -ne 0) { throw "failed to record Windows validation" }
if ($env:REQUIRE_WEBGPU -eq "1") {
    "PHYSICAL_DEVICE=passed" | Tee-Object -FilePath (Join-Path $distRoot "$target/smoke.log") -Append
    "ASSET_SHA256=$((Get-FileHash $asset -Algorithm SHA256).Hash.ToLowerInvariant())" | Tee-Object -FilePath (Join-Path $distRoot "$target/smoke.log") -Append
}
