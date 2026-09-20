[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$buildRoot = if ($env:BUILD_ROOT) { $env:BUILD_ROOT } else { Join-Path $repoRoot '.build/windows-x64' }
$buildRoot = [IO.Path]::GetFullPath($buildRoot)
$sourceDir = Join-Path $buildRoot 'hermes-src'
$buildDir = Join-Path $buildRoot 'hermes-build'
$distDir = if ($env:DIST_DIR) { $env:DIST_DIR } else { Join-Path $repoRoot 'dist' }
$distDir = [IO.Path]::GetFullPath($distDir)
$version = if ($env:PACKAGE_VERSION) { $env:PACKAGE_VERSION } else { 'dev' }
if ($version -notmatch '\A[0-9A-Za-z._-]+\z') { throw 'Invalid PACKAGE_VERSION.' }
$metadata = Get-Content (Join-Path $buildDir 'static-hermes-build.json') -Raw | ConvertFrom-Json
if ($metadata.platform -ne 'windows-x64') { throw 'Expected a Windows x64 build.' }
$packageName = "static-hermes-$version-windows-x64"
$stage = Join-Path $distDir $packageName
$archive = "$stage.tar.gz"
New-Item -ItemType Directory -Force $distDir | Out-Null
if (Test-Path $stage) {
  $resolvedStage = (Resolve-Path -LiteralPath $stage).Path
  if ($resolvedStage -ne [IO.Path]::GetFullPath((Join-Path $distDir $packageName))) {
    throw 'Unexpected staging directory.'
  }
  Remove-Item -LiteralPath $resolvedStage -Recurse -Force
}
foreach ($directory in @('bin', 'include/config', 'lib', 'share/licenses')) {
  New-Item -ItemType Directory -Force (Join-Path $stage $directory) | Out-Null
}
Copy-Item -LiteralPath "$buildDir/bin/shermes.exe" -Destination "$stage/bin/"
$binaryText = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes("$stage/bin/shermes.exe"))
if ($binaryText.Contains($buildRoot) -or $binaryText.Contains($buildRoot.Replace('\', '/'))) {
  throw 'The packaged shermes still contains its build directory.'
}
Copy-Item -LiteralPath "$sourceDir/include/hermes" -Destination "$stage/include/" -Recurse
Copy-Item -LiteralPath "$buildDir/lib/config/libhermesvm-config.h" -Destination "$stage/include/config/"
foreach ($library in @('lib/hermesvm_a.lib', 'jsi/jsi.lib', 'tools/shermes/shermes_console_a.lib')) {
  Copy-Item -LiteralPath (Join-Path $buildDir $library) -Destination "$stage/lib/"
}
$boost = @(Get-ChildItem "$buildDir/external/boost" -Filter boost_context.lib -Recurse)
if ($boost.Count -ne 1) { throw 'Expected exactly one Boost.Context static library.' }
Copy-Item -LiteralPath $boost[0].FullName -Destination "$stage/lib/"
Copy-Item -LiteralPath "$repoRoot/README.md" -Destination $stage
$licenses = @{
  'static-hermes-cli/LICENSE' = "$repoRoot/LICENSE"
  'hermes/LICENSE' = "$sourceDir/LICENSE"
  'boost/LICENSE_1_0.txt' = "$sourceDir/external/boost/boost_1_86_0/LICENSE_1_0.txt"
  'dragonbox/NOTICE.txt' = "$repoRoot/licenses/dragonbox-NOTICE.txt"
  'dtoa/dtoa-LICENSE.txt' = "$repoRoot/licenses/dtoa-LICENSE.txt"
  'dtoa/g_fmt-LICENSE.txt' = "$repoRoot/licenses/g_fmt-LICENSE.txt"
  'fast_float/LICENSE.txt' = "$repoRoot/licenses/fast_float-LICENSE.txt"
  'hermes-regex/LICENSE.txt' = "$sourceDir/include/hermes/Regex/LICENSE.TXT"
  'llvh/LICENSE.txt' = "$sourceDir/external/llvh/LICENSE.txt"
  'zip/UNLICENSE' = "$sourceDir/external/zip/UNLICENSE"
}
foreach ($entry in $licenses.GetEnumerator()) {
  $destination = Join-Path "$stage/share/licenses" $entry.Key
  New-Item -ItemType Directory -Force (Split-Path $destination -Parent) | Out-Null
  Copy-Item -LiteralPath $entry.Value -Destination $destination
}
@{
  schemaVersion = 1
  name = 'static-hermes'
  version = $version
  platform = $metadata.platform
  hermesRevision = $metadata.hermesRevision
  linkage = 'static-hermes-runtime'
  codeSignature = 'none'
  visualStudioVersion = $metadata.visualStudioVersion
  windowsSDKVersion = $metadata.windowsSDKVersion
  compilerVersion = $metadata.compilerVersion
  runtimeLibrary = 'MD'
} | ConvertTo-Json | Set-Content "$stage/manifest.json" -Encoding utf8
& tar -czf $archive -C $distDir $packageName
if ($LASTEXITCODE -ne 0) { throw 'Archive creation failed.' }
$checksum = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content "$archive.sha256" "$checksum  $packageName.tar.gz" -Encoding ascii
Write-Output "Created $archive"
