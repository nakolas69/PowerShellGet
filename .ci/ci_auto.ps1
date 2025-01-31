name: $(BuildDefinitionName)-$(date:yyMM).$(date:dd)$(rev:rrr)
trigger: none
pr: none

schedules:
# Use https://crontab.guru/#0_8_*_*_* to compute crontab expression
# Temporary schedule to run every 30 minutes, to investigate test failures
# - cron: "*/30 * * * *"
# Run signed build, with limited signing cert, every day at 9 am
- cron: 0 9 * * *
  branches:
    include:
    - refs/heads/master
  always: true

variables:
  - group: ESRP

resources:
  repositories:
  - repository: ComplianceRepo
    type: github
    endpoint: ComplianceGHRepo
    name: PowerShell/compliance

stages:
- stage: Build
  displayName: Build PowerShellGet Module Package
  jobs:
  - job: BuildPkg
    displayName: Build Package
    pool:
      name: 1ES
      demands:
      - ImageOverride -equals MMS2019

    steps:

    - pwsh: |
        Get-ChildItem -Path env:
        Get-ChildItem -Path env:
      displayName: Capture environment for build
      condition: succeededOrFailed()

    - pwsh: |
        $modulePath = Join-Path -Path $env:AGENT_TEMPDIRECTORY -ChildPath 'TempModules'
        if (Test-Path -Path $modulePath) {
          Write-Verbose -Verbose "Deleting existing temp module path: $modulePath"
          Remove-Item -Path $modulePath -Recurse -Force -ErrorAction Ignore
        }
        if (! (Test-Path -Path $modulePath)) {
          Write-Verbose -Verbose "Creating new temp module path: $modulePath"
          $null = New-Item -Path $modulePath -ItemType Directory
        }
      displayName: Create temporary module path

    - pwsh: |
        $modulePath = Join-Path -Path $env:AGENT_TEMPDIRECTORY -ChildPath 'TempModules'
        Write-Verbose -Verbose "Install PowerShellGet V3 to temp module path"
        Save-Module -Name PowerShellGet -Path $modulePath -MinimumVersion 3.0.0-beta10 -AllowPrerelease -Force
        Write-Verbose -Verbose "Install PlatyPS to temp module path"
        Save-Module -Name "platyPS" -Path $modulePath -Force
        Write-Verbose -Verbose "Install PSScriptAnalyzer to temp module path"
        Save-Module -Name "PSScriptAnalyzer" -Path $modulePath -RequiredVersion 1.18.0 -Force
        Write-Verbose -Verbose "Install Pester 5.X to temp module path"
        Save-Module -Name "Pester" -MinimumVersion 5.0 -Path $modulePath -Repository PSGallery -Force
        Write-Verbose -Verbose "Install PSPackageProject to temp module path"
        Save-Module -Name PSPackageProject -Path $modulePath -Force
      displayName: Install PSPackageProject and dependencies

    - pwsh: |
        $modulePath = Join-Path -Path $env:AGENT_TEMPDIRECTORY -ChildPath 'TempModules'
        $env:PSModulePath = $modulePath + [System.IO.Path]::PathSeparator + $env:PSModulePath
        $modPath = Join-Path -Path $modulePath -ChildPath PSPackageProject
        Write-Verbose -Verbose "Importing PSPackageProject from: $modPath"
        Import-Module -Name $modPath -Force
        #
        # Build for netstandard2.0 framework
        $(Build.SourcesDirectory)/build.ps1 -Build -Clean -BuildConfiguration Release -BuildFramework 'netstandard2.0'
      displayName: Build and publish artifact

    - pwsh: |
        $signSrcPath = "$($config.BuildOutputPath)"
        $vstsCommandString = "vso[task.setvariable variable=signSrcPath]${signSrcPath}"
        Write-Host "sending " + $vstsCommandString
        Write-Host "##$vstsCommandString"
        #
        $outSignPath = "$($config.BuildOutputPath)"
        $vstsCommandString = "vso[task.setvariable variable=signOutPath]${outSignPath}"
        Write-Host "sending " + $vstsCommandString
        Write-Host "##$vstsCommandString"
      displayName: Create fake source and output variables for signing template and no signing
      condition: succeeded()

    - pwsh: |
        $modulePath = Join-Path -Path $env:AGENT_TEMPDIRECTORY -ChildPath 'TempModules'
        $env:PSModulePath = $modulePath + [System.IO.Path]::PathSeparator + $env:PSModulePath
        $modPath = Join-Path -Path $modulePath -ChildPath PSPackageProject
        Write-Verbose -Verbose "Importing PSPackageProject from: $modPath"
        Import-Module -Name $modPath -Force

        $config = Get-PSPackageProjectConfiguration

        # Created files signing directory
        $srcPath = "$($config.BuildOutputPath)\$($config.ModuleName)"
        $createdSignSrcPath = "$($config.BuildOutputPath)\CreatedFiles"
        if (! (Test-Path -Path $createdSignSrcPath)) {
          $null = New-Item -Path $createdSignSrcPath -ItemType Directory -Verbose
        }
        Copy-Item -Path (Join-Path -Path $srcPath -ChildPath "PowerShellGet.psd1") -Dest $createdSignSrcPath -Force -Verbose
        Copy-Item -Path (Join-Path -Path $srcPath -ChildPath "PSGet.Format.ps1xml") -Dest $createdSignSrcPath -Force -Verbose
        Copy-Item -Path (Join-Path -Path $srcPath -ChildPath "DscResources") -Dest $createdSignSrcPath -Recurse -Force -Verbose
        Copy-Item -Path (Join-Path -Path $srcPath -ChildPath "Modules") -Dest $createdSignSrcPath -Recurse -Force -Verbose

        $netStandardPath = Join-Path -Path $createdSignSrcPath -ChildPath "netstandard2.0"
        if (! (Test-Path -Path $netStandardPath)) {
          $null = New-Item -Path $netStandardPath -ItemType Directory -Verbose
        }
        Copy-Item -Path (Join-Path -Path $srcPath -ChildPath "netstandard2.0\PowerShellGet.*") -Dest $netStandardPath -Force -Verbose
        
        $signOutPath = "$($config.SignedOutputPath)\$($config.ModuleName)"
        if (! (Test-Path -Path $signOutPath)) {
          $null = New-Item -Path $signOutPath -ItemType Directory
        }

        # Set signing src path variable
        $vstsCommandString = "vso[task.setvariable variable=signSrcPath]${createdSignSrcPath}"
        Write-Host "sending " + $vstsCommandString
        Write-Host "##$vstsCommandString"

        $outSignPath = "$($config.SignedOutputPath)\$($config.ModuleName)"
        if (! (Test-Path -Path $outSignPath)) {
          $null = New-Item -Path $outSignPath -ItemType Directory -Verbose
        }

        # Set signing out path variable
        $vstsCommandString = "vso[task.setvariable variable=signOutPath]${outSignPath}"
        Write-Host "sending " + $vstsCommandString
        Write-Host "##$vstsCommandString"
      displayName: Set up for module created files code signing
      condition: succeeded()

    - pwsh: |
        Get-ChildItem -Path env:
        Get-ChildItem -Path . -Recurse -Directory
      displayName: Capture environment for code signing
      condition: succeededOrFailed()

    - template: EsrpSign.yml@ComplianceRepo
      parameters:
        buildOutputPath: $(signSrcPath)
        signOutputPath: $(signOutPath)
        certificateId: "CP-460906"
        shouldSign: $(ShouldSign)
        pattern: |
          **\*.dll
          **\*.psd1
          **\*.psm1
          **\*.ps1xml
          **\*.mof
        useMinimatch: true

    - pwsh: |
        $modulePath = Join-Path -Path $env:AGENT_TEMPDIRECTORY -ChildPath 'TempModules'
        $env:PSModulePath = $modulePath + [System.IO.Path]::PathSeparator + $env:PSModulePath
        $modPath = Join-Path -Path $modulePath -ChildPath PSPackageProject
        Write-Verbose -Verbose "Importing PSPackageProject from: $modPath"
        Import-Module -Name $modPath -Force

        $config = Get-PSPackageProjectConfiguration

        $signOutPath = "$($config.SignedOutputPath)\$($config.ModuleName)"
        if (! (Test-Path -Path $signOutPath)) {
          $null = New-Item -Path $signOutPath -ItemType Directory
        }

        # Third party files signing directory
        $srcPath = "$($config.BuildOutputPath)\$($config.ModuleName)"
        $thirdPartySignSrcPath = "$($config.BuildOutputPath)\ThirdParty"
        if (! (Test-Path -Path $thirdPartySignSrcPath)) {
          $null = New-Item -Path $thirdPartySignSrcPath -ItemType Directory -Verbose
        }
        
        # NetStandard directory
        $netStandardPath = Join-Path -Path $thirdPartySignSrcPath -ChildPath "netstandard2.0"
        if (! (Test-Path -Path $netStandardPath)) {
          $null = New-Item -Path $netStandardPath -ItemType Directory -Verbose
        }
        Get-ChildItem -Path (Join-Path -Path $srcPath -ChildPath "netstandard2.0") -Filter '*.dll' | Foreach-Object {
          if ($_.Name -ne 'PowerShellGet.dll') {
            $sig = Get-AuthenticodeSignature -FilePath $_.FullName
            if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notlike '*Microsoft*' -or $sig.SignerCertificate.Issuer -notlike '*Microsoft Code Signing PCA*') {
              # Copy for third party signing
              Copy-Item -Path $_.FullName -Dest $netStandardPath -Force -Verbose
            }
          }
        }

        # Set signing src path variable
        $vstsCommandString = "vso[task.setvariable variable=signSrcPath]${thirdPartySignSrcPath}"
        Write-Host "sending " + $vstsCommandString
        Write-Host "##$vstsCommandString"

        # Set signing out path variable
        $vstsCommandString = "vso[task.setvariable variable=signOutPath]${signOutPath}"
        Write-Host "sending " + $vstsCommandString
        Write-Host "##$vstsCommandString"
      displayName: Set up for module third party files code signing
      condition: succeeded()

    - template: EsrpSign.yml@ComplianceRepo
      parameters:
        buildOutputPath: $(signSrcPath)
        signOutputPath: $(signOutPath)
        certificateId: "CP-231522"
        shouldSign: $(ShouldSign)
        pattern: |
          **\*.dll
        useMinimatch: true

    - pwsh: |
        $modulePath = Join-Path -Path $env:AGENT_TEMPDIRECTORY -ChildPath 'TempModules'
        $env:PSModulePath = $modulePath + [System.IO.Path]::PathSeparator + $env:PSModulePath
        $modPath = Join-Path -Path $modulePath -ChildPath PSPackageProject
        Write-Verbose -Verbose "Importing PSPackageProject from: $modPath"
        Import-Module -Name $modPath -Force

        $config = Get-PSPackageProjectConfiguration

        $srcPath = "$($config.BuildOutputPath)\$($config.ModuleName)"
        $signOutPath = "$($config.SignedOutputPath)\$($config.ModuleName)"
        if (! (Test-Path -Path $signOutPath)) {
          $null = New-Item -Path $signOutPath -ItemType Directory
        }

        # en-US
        Copy-Item -Path (Join-Path -Path $srcPath -ChildPath "en-US") -Dest $signOutPath -Recurse

        # NetStandard directory
        $netStandardSignedOutPath = Join-Path -Path $signOutPath -ChildPath "netstandard2.0"
        if (! (Test-Path -Path $netStandardSignedOutPath)) {
          $null = New-Item -Path $netStandardSignedOutPath -ItemType Directory -Verbose
        }
        Get-ChildItem -Path (Join-Path -Path $srcPath -ChildPath "netstandard2.0") -Filter '*.dll' | Foreach-Object {
          if ($_.Name -ne 'PowerShellGet.dll') {
            $sig = Get-AuthenticodeSignature -FilePath $_.FullName
            if ($sig.Status -eq 'Valid' -and ($sig.SignerCertificate.Subject -like '*Microsoft*' -and $sig.SignerCertificate.Issuer -like '*Microsoft Code Signing PCA*')) {
              # Copy already signed files directly to output
              Copy-Item -Path $_.FullName -Dest $netStandardSignedOutPath -Force -Verbose
            }
          }
        }
      displayName: Copy already properly signed third party files
      condition: succeeded()

    - pwsh: |
        $modulePath = Join-Path -Path $env:AGENT_TEMPDIRECTORY -ChildPath 'TempModules'
        $env:PSModulePath = $modulePath + [System.IO.Path]::PathSeparator + $env:PSModulePath
        $modPath = Join-Path -Path $modulePath -ChildPath PSPackageProject
        Write-Verbose -Verbose "Importing PSPackageProject from: $modPath"
        Import-Module -Name $modPath -Force
        #
        $config = Get-PSPackageProjectConfiguration
        $artifactName = "$($config.ModuleName)"
        $srcModulePath = Resolve-Path -Path "$($config.SignedOutputPath)/$($config.ModuleName)"
        Get-ChildItem $srcModulePath
        Write-Host "##vso[artifact.upload containerfolder=$artifactName;artifactname=$artifactName;]$srcModulePath"
        #
        $(Build.SourcesDirectory)/build.ps1 -Publish -Signed
      displayName: Create signed module artifact

- stage: Compliance
  displayName: Compliance
  dependsOn: Build
  jobs:
  - job: ComplianceJob
    pool:
      name: 1ES
      demands:
      - ImageOverride -equals MMS2019

    steps:
    - checkout: self
      clean: true
    - checkout: ComplianceRepo
      clean: true
    - download: current
      artifact: 'PowerShellGet'
    - template: assembly-module-compliance.yml@ComplianceRepo
      parameters:
        # binskim
        AnalyzeTarget: '$(Pipeline.Workspace)/PowerShellGet/netstandard2.0/PowerShellGet.dll'
        AnalyzeSymPath: 'SRV*'
        # component-governance
        sourceScanPath: '$(Build.SourcesDirectory)'
        # credscan
        suppressionsFile: ''
        # TermCheck
        optionsRulesDBPath: ''
        optionsFTPath: ''
        # tsa-upload
        codeBaseName: 'PowerShellGet_210306'
        # selections
        APIScan: false # set to false when not using Windows APIs

- stage: Test
  displayName: Test Package
  dependsOn: Build
  jobs:
  - template: test.yml
    parameters:
      jobName: TestPkgWin
      displayName: PowerShell Core on Windows
      imageName: windows-latest
  
  - template: test.yml
    parameters:
      jobName: TestPkgWinPS
      displayName: Windows PowerShell on Windows
      imageName: windows-latest
      powershellExecutable: powershell

  - template: test.yml
    parameters:
      jobName: TestPkgUbuntu16
      displayName: PowerShell Core on Ubuntu 16.04
      imageName: ubuntu-16.04

  - template: test.yml
    parameters:
      jobName: TestPkgWinMacOS
      displayName: PowerShell Core on macOS
      imageName: macOS-10.14
