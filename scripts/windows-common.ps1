function Invoke-Checked {
  param([string]$Command, [string[]]$Arguments)
  & $Command @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE" }
}

function Get-WindowsBuildConfiguration {
  if (![Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    throw 'These scripts require Windows.'
  }
  $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
  $platform = "windows-$architecture"
  if ($env:PLATFORM -and $env:PLATFORM -ne $platform) {
    throw "Expected $env:PLATFORM, but this host is $platform. Windows builds and tests must run natively."
  }
  switch ($architecture) {
    'x64' {
      $vsArchitecture = 'amd64'
      $component = 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'
      $clangTarget = 'x86_64-pc-windows-msvc'
      $boostArchitecture = 'x86_64'
      $boostImplementation = 'fcontext'
      $machine = '8664'
    }
    'arm64' {
      $vsArchitecture = 'arm64'
      $component = 'Microsoft.VisualStudio.Component.VC.Tools.ARM64'
      $clangTarget = 'aarch64-pc-windows-msvc'
      $boostArchitecture = 'arm64'
      $boostImplementation = 'winfib'
      $machine = 'AA64'
    }
    default { throw "Unsupported Windows architecture: $architecture" }
  }
  return [pscustomobject]@{
    Architecture = $architecture
    Platform = $platform
    VsArchitecture = $vsArchitecture
    Component = $component
    ClangTarget = $clangTarget
    BoostArchitecture = $boostArchitecture
    BoostImplementation = $boostImplementation
    Machine = $machine
  }
}

function Initialize-WindowsToolchain {
  param([Parameter(Mandatory)]$Configuration)
  $env:VSLANG = '1033'
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
  if (!(Test-Path $vswhere)) { throw 'Visual Studio with the C++ build tools is required.' }
  $vsPath = & $vswhere -latest -version '[17.0,)' -products '*' -requires $Configuration.Component -property installationPath
  if ($LASTEXITCODE -ne 0 -or !$vsPath) {
    throw "Visual Studio 2022 or later with C++ $($Configuration.Architecture) build tools is required ($($Configuration.Component))."
  }
  Import-Module (Join-Path $vsPath 'Common7/Tools/Microsoft.VisualStudio.DevShell.dll')
  $devArguments = "-arch=$($Configuration.VsArchitecture) -host_arch=$($Configuration.VsArchitecture)"
  Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments $devArguments | Out-Host
  return $vsPath
}
