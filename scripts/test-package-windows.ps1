[CmdletBinding()]
param([Parameter(Mandatory)][string]$Archive)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/windows-common.ps1"
$configuration = Get-WindowsBuildConfiguration
$repoRoot = Split-Path $PSScriptRoot -Parent
$archivePath = (Resolve-Path -LiteralPath $Archive).Path
$expected = (Get-Content "$archivePath.sha256" -Raw).Trim() -split '\s+', 2
if ($expected[1] -ne [IO.Path]::GetFileName($archivePath) -or
    (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -ne $expected[0]) {
  throw 'Archive checksum mismatch.'
}
$null = Initialize-WindowsToolchain $configuration
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
  $manifest = Get-Content "$relocated/manifest.json" -Raw | ConvertFrom-Json
  if ($manifest.platform -ne $configuration.Platform -or $manifest.hermesRevision -notmatch '^[0-9a-f]{40}$') {
    throw 'Invalid manifest or package architecture does not match this host.'
  }
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
  $objectHeaders = Invoke-Checked dumpbin @('/headers', "$outputDir/hello.obj")
  if (!($objectHeaders -match "$($configuration.Machine) machine")) {
    throw "Expected a $($configuration.Architecture) object file."
  }
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
    if (!($headers -match "$($configuration.Machine) machine")) {
      throw "Expected $($configuration.Architecture) executable: $executable"
    }
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
  Write-Output 'Package passed relocation, compile, static-link, and runtime tests.'
} finally {
  $env:PATH = $originalPath
  $resolvedWork = (Resolve-Path -LiteralPath $work).Path
  if ($resolvedWork -eq [IO.Path]::GetFullPath($work) -and
      (Split-Path $resolvedWork -Parent) -eq [IO.Path]::GetTempPath().TrimEnd('\', '/')) {
    Remove-Item -LiteralPath $resolvedWork -Recurse -Force
  }
}
