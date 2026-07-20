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
$packageLabel = switch ($versions.PACKAGE_CHANNEL) {
    "pilot" { "pilot.$($versions.PACKAGE_REVISION)"; break }
    "stable" { "r$($versions.PACKAGE_REVISION)"; break }
    default { throw "unsupported PACKAGE_CHANNEL: $($versions.PACKAGE_CHANNEL)" }
}
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
    "onnxruntime_ENABLE_DAWN_BACKEND_D3D12=1",
    "onnxruntime_ENABLE_DAWN_BACKEND_VULKAN=0"
)
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

if ($target -eq "windows-arm64") {
    $warnings = @(Select-String -Path $buildLog -Pattern 'warning C\d{4}:' | ForEach-Object { $_.Line })
    $undeclaredCalls = @($warnings | Where-Object { $_ -match 'warning C4013:' })
    if ($undeclaredCalls.Count -ne 0) {
        throw "Windows ARM64 build contains undeclared function calls: $($undeclaredCalls -join [Environment]::NewLine)"
    }

    $missingReturnWarnings = @($warnings | Where-Object { $_ -match 'warning C4715:' })
    $allowedWarnings = @(
        'BackendD3D\.cpp\(73\): warning C4715: .*ToDXGIPowerPreference',
        'UtilsD3D\.cpp\(420\): warning C4715: .*DXGITextureFormat',
        'UtilsD3D\.cpp\(265\): warning C4715: .*DXGITypelessTextureFormat'
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
    "ORT_REF=$($versions.ORT_REF)",
    "ORT_VERSION=$($versions.ORT_VERSION)",
    "ORT_COMMIT=$commit",
    "PACKAGING_COMMIT=$packagingCommit",
    "PACKAGE_CHANNEL=$($versions.PACKAGE_CHANNEL)",
    "PACKAGE_REVISION=$($versions.PACKAGE_REVISION)",
    "PACKAGE_LABEL=$packageLabel",
    "TARGET=$target",
    "ORT_CORE_INCLUDED=1",
    "WEBGPU_LINKAGE=plugin-shared",
    "EXECUTION_PROVIDERS=WebGPU,CPU",
    "BUILD_CONFIG=Release"
) -join "`n") + "`n"
$packageManifest = Join-Path $packageDir "manifest.env"
[System.IO.File]::WriteAllText($packageManifest, $manifestText, $utf8NoBom)

$assetName = "onnxruntime-webgpu-$target-$($versions.ORT_VERSION)-$packageLabel.zip"
$asset = Join-Path $distDir $assetName
Compress-Archive -Path (Join-Path $packageDir "*") -DestinationPath $asset
$hash = (Get-FileHash $asset -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText("$asset.sha256", "$hash`n", $utf8NoBom)
[System.IO.File]::WriteAllText("$asset.manifest.env", $manifestText, $utf8NoBom)
Write-Host "created $asset"
