[CmdletBinding()]
param([Parameter(Mandatory)][string]$Archive)

$ErrorActionPreference = 'Stop'
$env:VSLANG = '1033'
$repoRoot = Split-Path $PSScriptRoot -Parent
$archivePath = (Resolve-Path -LiteralPath $Archive).Path
$expected = (Get-Content "$archivePath.sha256" -Raw).Trim() -split '\s+', 2
if ($expected[1] -ne [IO.Path]::GetFileName($archivePath) -or
    (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -ne $expected[0]) {
  throw 'Archive checksum mismatch.'
}
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
foreach ($command in @('clang', 'dumpbin', 'tar')) {
  if (!(Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required command not found: $command" }
}
$work = Join-Path ([IO.Path]::GetTempPath()) ("static-hermes-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work | Out-Null
$originalPath = $env:PATH
try {
  Invoke-Checked tar @('-xzf', $archivePath, '-C', $work)
  $packages = @(Get-ChildItem $work -Directory -Filter 'static-hermes-*')
  if ($packages.Count -ne 1) { throw 'Expected exactly one package directory.' }
  $relocated = Join-Path $work 'relocated toolchain 日本語'
  if ($packages[0].Parent.FullName -ne (Resolve-Path $work).Path) { throw 'Unexpected package path.' }
  Move-Item -LiteralPath $packages[0].FullName -Destination $relocated
  $shermes = Join-Path $relocated 'bin/shermes.exe'
  $env:PATH = "$relocated/bin;$originalPath"
  $outputDir = Join-Path $work 'output'
  New-Item -ItemType Directory $outputDir | Out-Null
  $compilerPath = $env:PATH
  try {
    $env:PATH = "$env:SystemRoot/System32;$env:SystemRoot"
    Invoke-Checked $shermes @('--version')
  } finally {
    $env:PATH = $compilerPath
  }
  Invoke-Checked $shermes @('-O', '-emit-c', '-o', "$outputDir/hello.c", "$repoRoot/tests/hello.js")
  Invoke-Checked $shermes @('-O', '-dump-ir', "$repoRoot/tests/hello.js") | Set-Content "$outputDir/hello.ir"
  Invoke-Checked 'shermes.exe' @('-O', '-c', '-o', "$outputDir/hello.obj", "$repoRoot/tests/hello.js")
  foreach ($test in @('hello', 'runtime')) {
    $executable = "$outputDir/$test.exe"
    Invoke-Checked $shermes @('-O', '-static-link', '-o', $executable, "$repoRoot/tests/$test.js")
    try {
      $env:PATH = "$env:SystemRoot/System32;$env:SystemRoot"
      $actual = Invoke-Checked $executable @()
    } finally {
      $env:PATH = $compilerPath
    }
    $expectedOutput = if ($test -eq 'hello') { 'hello' } else { 'runtime ok' }
    if ($actual -ne $expectedOutput) { throw "Unexpected output from ${test}: $actual" }
  }
  foreach ($executable in @($shermes, "$outputDir/hello.exe", "$outputDir/runtime.exe")) {
    $headers = Invoke-Checked dumpbin @('/headers', $executable)
    if (!($headers -match '8664 machine')) { throw "Expected x64 executable: $executable" }
    $dependencies = Invoke-Checked dumpbin @('/dependents', $executable)
    foreach ($line in $dependencies) {
      if ($line -match '^\s+(\S+\.dll)\s*$') {
        $dependency = $Matches[1]
        if ($dependency -match '(hermes|shermes|jsi|boost)' -or
            ($dependency -notmatch '^api-ms-win-' -and
             !(Test-Path -LiteralPath (Join-Path "$env:SystemRoot/System32" $dependency)))) {
          throw "Unexpected or unavailable dependency: $dependency"
        }
      }
    }
  }
  $manifest = Get-Content "$relocated/manifest.json" -Raw | ConvertFrom-Json
  if ($manifest.platform -ne 'windows-x64' -or $manifest.hermesRevision -notmatch '^[0-9a-f]{40}$') {
    throw 'Invalid manifest.'
  }
  Write-Output 'Package passed relocation, compile, static-link, and runtime tests.'
} finally {
  $env:PATH = $originalPath
  $resolvedWork = (Resolve-Path -LiteralPath $work).Path
  if ($resolvedWork -eq [IO.Path]::GetFullPath($work) -and
      (Split-Path $resolvedWork -Parent) -eq [IO.Path]::GetTempPath().TrimEnd('\', '/')) {
    Remove-Item -LiteralPath $resolvedWork -Recurse -Force
  }
}
