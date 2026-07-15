$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$versions = @{}
Get-Content (Join-Path $RepoRoot "versions.env") | ForEach-Object {
    if ($_ -match '^([^#=]+)=(.*)$') { $versions[$Matches[1]] = $Matches[2] }
}

$target = if ($args.Count -gt 0) { $args[0] } else { "" }
if ($target -notin @("windows-x64", "windows-arm64")) {
    throw "usage: build-windows.ps1 <windows-x64|windows-arm64>"
}

$ortSource = if ($env:ORT_SOURCE_DIR) { $env:ORT_SOURCE_DIR } else { Join-Path $RepoRoot "onnxruntime" }
$buildRoot = if ($env:BUILD_ROOT) { $env:BUILD_ROOT } else { Join-Path $RepoRoot "build" }
$distRoot = if ($env:DIST_ROOT) { $env:DIST_ROOT } else { Join-Path $RepoRoot "dist" }
$buildDir = Join-Path $buildRoot $target
$distDir = Join-Path $distRoot $target
$packageDir = Join-Path $distDir "package"

# Strawberry Perl puts an obsolete patch.exe (2.5.9) on hosted runners' PATH.
# Git for Windows ships a current GNU patch implementation.
$gitPatchDir = Join-Path $env:ProgramFiles "Git\usr\bin"
$gitPatch = Join-Path $gitPatchDir "patch.exe"
if (-not (Test-Path $gitPatch)) { throw "missing Git for Windows patch.exe: $gitPatch" }
$env:PATH = "$gitPatchDir;$env:PATH"

$hostArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
$requiredHostArch = if ($target -eq "windows-arm64") { "Arm64" } else { "X64" }
if ($hostArch -ne $requiredHostArch) {
    throw "$target must build on a native $requiredHostArch runner; found $hostArch"
}

$actualRef = git -C $ortSource describe --tags --exact-match
if ($actualRef -ne $versions.ORT_REF) { throw "expected ORT $($versions.ORT_REF), found $actualRef" }
git -C $ortSource apply --reverse --check (Join-Path $RepoRoot "patches/onnxruntime-public-vcpkg.patch") 2>$null
if ($LASTEXITCODE -ne 0) {
    git -C $ortSource apply (Join-Path $RepoRoot "patches/onnxruntime-public-vcpkg.patch")
    if ($LASTEXITCODE -ne 0) { throw "failed to apply public-vcpkg patch" }
}

Remove-Item $buildDir, $distDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item $packageDir -ItemType Directory -Force | Out-Null

$buildArgs = @(
    (Join-Path $ortSource "tools/ci_build/build.py"),
    "--build_dir", $buildDir,
    "--config", "Release",
    "--parallel",
    "--skip_tests",
    "--use_vcpkg",
    "--use_webgpu", "shared_lib",
    "--wgsl_template", "static",
    "--disable_rtti",
    "--enable_lto",
    "--cmake_generator", "Visual Studio 17 2022",
    "--cmake_extra_defines",
    "onnxruntime_BUILD_UNIT_TESTS=OFF",
    "onnxruntime_ENABLE_DAWN_BACKEND_D3D12=1",
    "onnxruntime_ENABLE_DAWN_BACKEND_VULKAN=0"
)
if ($target -eq "windows-arm64") {
    # Native ARM64 MSVC reports benign C4702 unreachable-code warnings during
    # WebGPU LTO. Use ORT's supported switch instead of patching Dawn sources.
    $buildArgs += "--compile_no_warning_as_error"
}
python @buildArgs
if ($LASTEXITCODE -ne 0) { throw "ONNX Runtime build failed" }

$outputDir = Join-Path $buildDir "Release/Release"
$plugin = Join-Path $outputDir "onnxruntime_providers_webgpu.dll"
if (-not (Test-Path $plugin)) { throw "missing WebGPU plugin: $plugin" }
Copy-Item $plugin $packageDir

# Match ONNX Runtime's official plugin packaging pipeline: distribute the
# checksum-pinned DXC release runtime for the target architecture rather than
# depending on incidental DLL placement in Dawn's build tree.
$dxcArchive = Join-Path $buildDir "dxc.zip"
$dxcExtract = Join-Path $buildDir "dxc"
$dxcUrl = "https://github.com/microsoft/DirectXShaderCompiler/releases/download/$($versions.DXC_VERSION)/dxc_2025_02_20.zip"
Invoke-WebRequest -Uri $dxcUrl -OutFile $dxcArchive
$dxcHash = (Get-FileHash $dxcArchive -Algorithm SHA256).Hash
if ($dxcHash -ne $versions.DXC_ARCHIVE_SHA256) {
    throw "DXC archive hash mismatch: expected $($versions.DXC_ARCHIVE_SHA256), found $dxcHash"
}
Expand-Archive -Path $dxcArchive -DestinationPath $dxcExtract -Force
$dxcArch = if ($target -eq "windows-arm64") { "arm64" } else { "x64" }
foreach ($dependency in @("dxcompiler.dll", "dxil.dll")) {
    $path = Join-Path $dxcExtract "bin/$dxcArch/$dependency"
    if (-not (Test-Path $path)) { throw "missing WebGPU dependency: $path" }
    Copy-Item $path $packageDir
}
Copy-Item (Join-Path $ortSource "LICENSE") (Join-Path $packageDir "ONNXRUNTIME-LICENSE")
if (Test-Path (Join-Path $ortSource "ThirdPartyNotices.txt")) {
    Copy-Item (Join-Path $ortSource "ThirdPartyNotices.txt") $packageDir
}

$commit = git -C $ortSource rev-parse HEAD
@"
ORT_REF=$($versions.ORT_REF)
ORT_VERSION=$($versions.ORT_VERSION)
ORT_COMMIT=$commit
PACKAGE_REVISION=$($versions.PACKAGE_REVISION)
TARGET=$target
WEBGPU_LINKAGE=plugin-shared
BUILD_CONFIG=Release
"@ | Set-Content (Join-Path $packageDir "manifest.env") -NoNewline

$assetName = "onnxruntime-webgpu-$target-$($versions.ORT_VERSION)-pilot.$($versions.PACKAGE_REVISION).zip"
$asset = Join-Path $distDir $assetName
Compress-Archive -Path (Join-Path $packageDir "*") -DestinationPath $asset
$hash = (Get-FileHash $asset -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $assetName" | Set-Content "$asset.sha256"
Write-Host "created $asset"
