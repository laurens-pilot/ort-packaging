$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$buildConfig = @{}
Get-Content (Join-Path $RepoRoot "build.env") | ForEach-Object {
    if ($_ -match '^([^#=]+)=(.*)$') { $buildConfig[$Matches[1]] = $Matches[2] }
}

if ($buildConfig.ORT_TELEMETRY -ne "disabled") { throw "ORT_TELEMETRY must be disabled" }
if ($env:ORT_VERSION -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
    throw "ORT_VERSION must be MAJOR.MINOR.PATCH"
}
if ($env:ORT_REF -ne "v$($env:ORT_VERSION)") { throw "ORT_REF must be v$($env:ORT_VERSION)" }
if ($env:ORT_COMMIT -notmatch '^[0-9a-f]{40}$') { throw "ORT_COMMIT must be a full commit SHA" }
if ($env:PACKAGE_REVISION -notmatch '^[1-9][0-9]*$') { throw "PACKAGE_REVISION must be a positive integer" }

function Assert-OrtTelemetryDisabled {
    param([string]$Root)

    $ortCaches = @()
    Get-ChildItem $Root -Filter CMakeCache.txt -Recurse -File | ForEach-Object {
        $settings = @(Select-String -Path $_.FullName -Pattern "^onnxruntime_USE_TELEMETRY:[^=]+=")
        if ($settings.Count -gt 0) {
            $ortCaches += $_.FullName
            if ($settings.Count -ne 1 -or $settings[0].Line -notmatch "^onnxruntime_USE_TELEMETRY:[^=]+=OFF$") {
                throw "ONNX Runtime telemetry is not disabled in $($_.FullName)"
            }
        }
    }
    if ($ortCaches.Count -eq 0) { throw "no ONNX Runtime telemetry setting found below $Root" }
}

$target = if ($args.Count -gt 0) { $args[0] } else { "" }
if ($target -notin @("windows-x64", "windows-arm64")) {
    throw "usage: build-windows.ps1 <windows-x64|windows-arm64>"
}

$ortSource = if ($env:ORT_SOURCE_DIR) { $env:ORT_SOURCE_DIR } else { Join-Path $RepoRoot "onnxruntime" }
$buildRoot = if ($env:BUILD_ROOT) { $env:BUILD_ROOT } else { Join-Path $RepoRoot "build" }
$distRoot = if ($env:DIST_ROOT) { $env:DIST_ROOT } else { Join-Path $RepoRoot "dist" }
$packageLabel = "r$($env:PACKAGE_REVISION)"
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

$actualCommit = git -C $ortSource rev-parse HEAD
if ($actualCommit -ne $env:ORT_COMMIT) { throw "expected ORT $($env:ORT_COMMIT), found $actualCommit" }
git -C $ortSource apply --reverse --check (Join-Path $RepoRoot "patches/onnxruntime-public-vcpkg.patch") 2>$null
if ($LASTEXITCODE -ne 0) {
    git -C $ortSource apply (Join-Path $RepoRoot "patches/onnxruntime-public-vcpkg.patch")
    if ($LASTEXITCODE -ne 0) { throw "failed to apply public-vcpkg patch" }
}

$ortBuildArgs = Join-Path $ortSource "tools/ci_build/build_args.py"
if (-not (Test-Path $ortBuildArgs)) { throw "missing ONNX Runtime build argument parser: $ortBuildArgs" }
$noTelemetrySupported = Select-String -Path $ortBuildArgs -Pattern '["'']--no_telemetry["'']' -Quiet

Remove-Item $buildDir, $distDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item $buildDir -ItemType Directory -Force | Out-Null
New-Item $packageDir -ItemType Directory -Force | Out-Null

$buildArgs = @(
    (Join-Path $ortSource "tools/ci_build/build.py"),
    "--build_dir", $buildDir,
    "--config", "Release",
    "--parallel",
    "--skip_tests",
    "--build_shared_lib",
    "--use_vcpkg",
    "--use_webgpu", "shared_lib",
    "--wgsl_template", "static",
    "--disable_rtti",
    "--enable_lto",
    "--cmake_generator", "Visual Studio 17 2022",
    "--cmake_extra_defines",
    "onnxruntime_BUILD_UNIT_TESTS=OFF",
    "onnxruntime_USE_TELEMETRY=OFF",
    "onnxruntime_ENABLE_DAWN_BACKEND_D3D12=1",
    "onnxruntime_ENABLE_DAWN_BACKEND_VULKAN=0"
)
if ($noTelemetrySupported) {
    $buildArgs += "--no_telemetry"
}
if ($target -eq "windows-arm64") {
    # KleidiAI 1.20.0 calls a half-float conversion that is not declared by its
    # MSVC ARM64 configuration. Keep the correct MLAS fallback until upstream
    # supports this toolchain rather than shipping a potentially dead-stripped
    # unresolved call.
    $buildArgs += "--no_kleidiai"

    # Dawn's pinned source has exhaustive enum switches ending in
    # DAWN_UNREACHABLE, which native ARM64 MSVC does not recognize as returning.
    # The exact warnings are allowlisted below and the packaged runtime is then
    # exercised by test-windows-runtime.ps1 in the same release job.
    $buildArgs += "--compile_no_warning_as_error"
}
$buildLog = Join-Path $buildDir "build.log"
python @buildArgs 2>&1 | Tee-Object -FilePath $buildLog
if ($LASTEXITCODE -ne 0) { throw "ONNX Runtime build failed" }
Assert-OrtTelemetryDisabled $buildDir

if ($target -eq "windows-arm64") {
    $warnings = @(Select-String -Path $buildLog -Pattern 'warning C\d{4}:' | ForEach-Object { $_.Line })
    $undeclaredCalls = @($warnings | Where-Object { $_ -match 'warning C4013:' })
    if ($undeclaredCalls.Count -ne 0) {
        throw "Windows ARM64 build contains undeclared function calls: $($undeclaredCalls -join [Environment]::NewLine)"
    }

    $missingReturnWarnings = @($warnings | Where-Object { $_ -match 'warning C4715:' })
    $allowedWarnings = @(
        "warning C4715: \x27.*::ToDXGIPowerPreference\x27: not all control paths return a value",
        "warning C4715: \x27.*::DXGITextureFormat\x27: not all control paths return a value",
        "warning C4715: \x27.*::DXGITypelessTextureFormat\x27: not all control paths return a value"
    )
    foreach ($warning in $missingReturnWarnings) {
        if (-not ($allowedWarnings | Where-Object { $warning -match $_ })) {
            throw "unexpected Windows ARM64 compiler warning: $warning"
        }
    }
    foreach ($pattern in $allowedWarnings) {
        $matches = @($missingReturnWarnings | Where-Object { $_ -match $pattern })
        if ($matches.Count -ne 1) {
            throw "expected exactly one pinned Dawn warning matching: $pattern"
        }
    }
}

$outputDir = Join-Path $buildDir "Release/Release"
$plugin = Join-Path $outputDir "onnxruntime_providers_webgpu.dll"
$core = Join-Path $outputDir "onnxruntime.dll"
$providersShared = Join-Path $outputDir "onnxruntime_providers_shared.dll"
if (-not (Test-Path $plugin)) { throw "missing WebGPU plugin: $plugin" }
if (-not (Test-Path $core)) { throw "missing ONNX Runtime core: $core" }
if (-not (Test-Path $providersShared)) { throw "missing shared provider runtime: $providersShared" }
Copy-Item $plugin, $core, $providersShared $packageDir
if (Get-ChildItem $packageDir -Filter "*.pdb" -Recurse) {
    throw "Windows runtime package must not contain debug symbol files"
}

# Match ONNX Runtime's official plugin packaging pipeline: distribute the
# checksum-pinned DXC release runtime for the target architecture rather than
# depending on incidental DLL placement in Dawn's build tree.
$dxcArchive = Join-Path $buildDir "dxc.zip"
$dxcExtract = Join-Path $buildDir "dxc"
$dxcUrl = "https://github.com/microsoft/DirectXShaderCompiler/releases/download/$($buildConfig.DXC_VERSION)/dxc_2025_02_20.zip"
Invoke-WebRequest -Uri $dxcUrl -OutFile $dxcArchive
$dxcHash = (Get-FileHash $dxcArchive -Algorithm SHA256).Hash
if ($dxcHash -ne $buildConfig.DXC_ARCHIVE_SHA256) {
    throw "DXC archive hash mismatch: expected $($buildConfig.DXC_ARCHIVE_SHA256), found $dxcHash"
}
Expand-Archive -Path $dxcArchive -DestinationPath $dxcExtract -Force
$dxcArch = if ($target -eq "windows-arm64") { "arm64" } else { "x64" }
foreach ($dependency in @("dxcompiler.dll", "dxil.dll")) {
    $path = Join-Path $dxcExtract "bin/$dxcArch/$dependency"
    if (-not (Test-Path $path)) { throw "missing WebGPU dependency: $path" }
    Copy-Item $path $packageDir
}
$dxcLicenses = [ordered]@{
    "LICENSE-LLVM.txt" = "DXC-LICENSE-LLVM.txt"
    "LICENSE-MIT.txt" = "DXC-LICENSE-MIT.txt"
    "LICENSE-MS.txt" = "DXC-LICENSE-MS.txt"
    "inc/hlsl/LICENSE.txt" = "DXC-HLSL-LICENSE.txt"
}
foreach ($license in $dxcLicenses.GetEnumerator()) {
    $source = Join-Path $dxcExtract $license.Key
    if (-not (Test-Path $source)) { throw "missing DXC license: $source" }
    Copy-Item $source (Join-Path $packageDir $license.Value)
}
Copy-Item (Join-Path $ortSource "LICENSE") (Join-Path $packageDir "ONNXRUNTIME-LICENSE")
if (Test-Path (Join-Path $ortSource "ThirdPartyNotices.txt")) {
    Copy-Item (Join-Path $ortSource "ThirdPartyNotices.txt") $packageDir
}

$commit = git -C $ortSource rev-parse HEAD
$packagingCommit = git -C $RepoRoot rev-parse HEAD
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$manifestText = (@(
    "ORT_REF=$($env:ORT_REF)",
    "ORT_VERSION=$($env:ORT_VERSION)",
    "ORT_TELEMETRY=$($buildConfig.ORT_TELEMETRY)",
    "ORT_COMMIT=$commit",
    "PACKAGING_COMMIT=$packagingCommit",
    "PACKAGE_CHANNEL=stable",
    "PACKAGE_REVISION=$($env:PACKAGE_REVISION)",
    "PACKAGE_LABEL=$packageLabel",
    "TARGET=$target",
    "ORT_CORE_INCLUDED=1",
    "WEBGPU_LINKAGE=plugin-shared",
    "EXECUTION_PROVIDERS=WebGPU,CPU",
    "BUILD_CONFIG=Release"
) -join "`n") + "`n"
$packageManifest = Join-Path $packageDir "manifest.env"
[System.IO.File]::WriteAllText($packageManifest, $manifestText, $utf8NoBom)

$assetName = "onnxruntime-webgpu-$target-$($env:ORT_VERSION)-$packageLabel.zip"
$asset = Join-Path $distDir $assetName
Compress-Archive -Path (Join-Path $packageDir "*") -DestinationPath $asset
$hash = (Get-FileHash $asset -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText("$asset.sha256", "$hash`n", $utf8NoBom)
[System.IO.File]::WriteAllText("$asset.manifest.env", $manifestText, $utf8NoBom)
Write-Host "created $asset"
