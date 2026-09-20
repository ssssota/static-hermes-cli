[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$env:VSLANG = '1033'
$repoRoot = Split-Path $PSScriptRoot -Parent
$buildRoot = if ($env:BUILD_ROOT) { $env:BUILD_ROOT } else { Join-Path $repoRoot '.build/windows-x64' }
$buildRoot = [IO.Path]::GetFullPath($buildRoot)
$sourceDir = Join-Path $buildRoot 'hermes-src'
$buildDir = Join-Path $buildRoot 'hermes-build'

function Invoke-Checked {
  param([string]$Command, [string[]]$Arguments)
  & $Command @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE" }
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (!(Test-Path $vswhere)) { throw 'Visual Studio with the C++ build tools is required.' }
$vsPath = & $vswhere -latest -version '[17.0,)' -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$vsPath) { throw 'Visual Studio 2022 or later with C++ x64 build tools is required.' }
Import-Module (Join-Path $vsPath 'Common7/Tools/Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments '-arch=amd64 -host_arch=amd64'

$cmake = if ($env:CMAKE_BIN) { $env:CMAKE_BIN } elseif (Get-Command cmake -ErrorAction SilentlyContinue) { 'cmake' } else {
  Join-Path $vsPath 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
}
$python = if ($env:PYTHON_BIN) { $env:PYTHON_BIN } else { 'python' }
foreach ($command in @($cmake, $python, 'git', 'tar', 'ninja', 'cl', 'clang')) {
  if (!(Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required command not found: $command" }
}
Invoke-Checked $python @('--version')
Invoke-Checked clang @('--version')
$revision = & git -C (Join-Path $repoRoot 'hermes') rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Initialize the Hermes submodule first.' }
$patches = @(Get-ChildItem (Join-Path $repoRoot 'patches/*.patch') | Sort-Object Name)
$fingerprint = "$revision`n" + (($patches | Get-FileHash -Algorithm SHA256).Hash -join "`n")
New-Item -ItemType Directory -Force $buildRoot | Out-Null
if (Test-Path $sourceDir) {
  $stamp = Join-Path $sourceDir '.static-hermes-source'
  if (!(Test-Path $stamp) -or (Get-Content $stamp -Raw).Trim() -ne $fingerprint.Trim()) {
    throw 'Prepared source is stale. Select a new BUILD_ROOT or remove the existing Windows build directory.'
  }
} else {
  New-Item -ItemType Directory $sourceDir | Out-Null
  $sourceArchive = Join-Path $buildRoot 'hermes-src.tar'
  Invoke-Checked git @('-C', "$repoRoot/hermes", 'archive', '--format=tar', "--output=$sourceArchive", $revision)
  Invoke-Checked tar @('-xf', $sourceArchive, '-C', $sourceDir)
  Remove-Item -LiteralPath $sourceArchive
  $gitDir = & git -C "$repoRoot/hermes" rev-parse --absolute-git-dir
  if ($LASTEXITCODE -ne 0) { throw 'Cannot locate Hermes Git metadata.' }
  foreach ($patch in $patches) {
    Invoke-Checked git @('-C', $sourceDir, "--git-dir=$gitDir", "--work-tree=$sourceDir", 'apply', $patch.FullName)
  }
  Set-Content -LiteralPath (Join-Path $sourceDir '.static-hermes-source') -Value $fingerprint
}

$jobs = if ($env:BUILD_JOBS) { $env:BUILD_JOBS } else { '4' }
if (Test-Path "$buildDir/static-hermes-build.json") {
  Remove-Item -LiteralPath "$buildDir/static-hermes-build.json"
}
Invoke-Checked $cmake @(
  '-S', $sourceDir, '-B', $buildDir, '-G', 'Ninja',
  '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_C_COMPILER=cl', '-DCMAKE_CXX_COMPILER=cl',
  '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL', '-DCMAKE_DISABLE_FIND_PACKAGE_ICU=ON',
  '-DHERMES_ENABLE_NAPI=OFF', '-DHERMES_ENABLE_TEST_SUITE=OFF',
  "-DPython_EXECUTABLE=$((Get-Command $python).Source)",
  '-DSHERMES_CC=clang', '-DSHERMES_CC_INCLUDE_PATH=', '-DSHERMES_CC_LIB_PATH='
)
Invoke-Checked $cmake @('--build', $buildDir, '--target', 'shermes', 'hermesvm_a', 'shermes_console_a', 'jsi', '--parallel', $jobs)
@{
  hermesRevision = $revision
  platform = 'windows-x64'
  visualStudioVersion = $env:VisualStudioVersion
  windowsSDKVersion = $env:WindowsSDKVersion
  compilerVersion = $env:VCToolsVersion
} | ConvertTo-Json | Set-Content (Join-Path $buildDir 'static-hermes-build.json')
