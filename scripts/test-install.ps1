#requires -Version 7.2

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$installerPath = Join-Path $repositoryRoot 'install.ps1'
$buildPath = Join-Path $PSScriptRoot 'build-release.ps1'
$releaseVersion = (Get-Content `
    -LiteralPath (Join-Path $repositoryRoot 'VERSION') `
    -Raw `
    -Encoding UTF8).Trim()
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'EL-Workspace-tests-' + [Guid]::NewGuid().ToString('N')
)
$installRoot = Join-Path $testRoot 'LocalAppData\EL-System-Tools\Terminal'
$profilePath = Join-Path $testRoot 'Documents\PowerShell\profile.ps1'
$fragmentPath = Join-Path $testRoot (
    'LocalAppData\Microsoft\Windows Terminal\' +
    'Fragments\EL.ProjectManager\projects.json'
)
$terminalSettingsPath = Join-Path $testRoot (
    'LocalAppData\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\' +
    'LocalState\settings.json'
)
$distPath = Join-Path $testRoot 'dist'
$secondDistPath = Join-Path $testRoot 'dist-second'
$savedEnvironment = [ordered]@{}

function Assert-True {
    param(
        [Parameter(Mandatory)][bool] $Condition,
        [Parameter(Mandatory)][string] $Message
    )
    if (-not $Condition) {
        throw "ASSERT: $Message"
    }
}

function Assert-Equal {
    param(
        [AllowNull()] $Actual,
        [AllowNull()] $Expected,
        [Parameter(Mandatory)][string] $Message
    )
    if (-not [object]::Equals($Actual, $Expected)) {
        throw "ASSERT: $Message (expected '$Expected', actual '$Actual')"
    }
}

function Set-TestEnvironment {
    $values = [ordered]@{
        EL_WORKSPACE_TEST_MODE = '1'
        EL_WORKSPACE_TEST_INSTALL_ROOT = $installRoot
        EL_WORKSPACE_TEST_ROOT = $installRoot
        EL_WORKSPACE_TEST_PROFILE = $profilePath
        EL_WORKSPACE_TEST_FRAGMENT = $fragmentPath
        EL_WORKSPACE_TEST_TERMINAL_SETTINGS = $terminalSettingsPath
        EL_WORKSPACE_TEST_FAIL_AFTER_SWAP = $null
    }
    foreach ($entry in $values.GetEnumerator()) {
        $savedEnvironment[$entry.Key] = [Environment]::GetEnvironmentVariable(
            $entry.Key,
            'Process'
        )
        [Environment]::SetEnvironmentVariable(
            $entry.Key,
            $entry.Value,
            'Process'
        )
    }
}

function Restore-TestEnvironment {
    foreach ($entry in $savedEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable(
            $entry.Key,
            $entry.Value,
            'Process'
        )
    }
}

function Write-Utf8 {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Content
    )
    [void] [IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function New-TestTerminalSettings {
    $settings = [ordered]@{
        '$schema' = 'https://aka.ms/terminal-profiles-schema'
        customRootSetting = 'preserve-me'
        profiles = [ordered]@{
            defaults = [ordered]@{ opacity = 91 }
            list = @(
                [ordered]@{
                    guid = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
                    name = 'PowerShell'
                    source = 'Windows.Terminal.PowershellCore'
                    hidden = $false
                    customProfileSetting = 'preserve-me-too'
                },
                [ordered]@{
                    guid = '{11111111-1111-1111-1111-111111111111}'
                    name = 'Unrelated profile'
                    commandline = 'cmd.exe'
                    colorScheme = 'Campbell'
                }
            )
        }
        schemes = @(
            [ordered]@{
                name = 'Existing Scheme'
                background = '#000000'
            }
        )
    } | ConvertTo-Json -Depth 30
    Write-Utf8 -Path $terminalSettingsPath -Content ($settings + "`n")
}

function Invoke-TestInstall {
    param(
        [Parameter(Mandatory)][string] $Source,
        [string] $Hash,
        [switch] $AsUpdate
    )
    $parameters = @{
        SourcePath = $Source
        SkipDependencies = $true
        Yes = $true
    }
    if ($Hash) {
        $parameters.SourceSha256 = $Hash
    }
    if ($AsUpdate) {
        $parameters.Update = $true
    }
    & $installerPath @parameters
}

function Assert-InstalledState {
    param(
        [Parameter(Mandatory)][string] $ProjectsHash,
        [Parameter(Mandatory)][string] $StateHash
    )
    foreach ($fileName in @(
        'el.ps1',
        'el-project.ps1',
        'workspace-pane.ps1',
        'el-workspace.ps1',
        'profile.ps1',
        'projects.json',
        'launcher-state.json',
        'install.json',
        'themes\el-midnight.omp.json',
        'themes\el-midnight.terminal.json'
    )) {
        Assert-True `
            -Condition (Test-Path `
                -LiteralPath (Join-Path $installRoot $fileName) `
                -PathType Leaf) `
            -Message "installed file missing: $fileName"
    }
    Assert-Equal `
        -Actual ((Get-FileHash `
            -LiteralPath (Join-Path $installRoot 'projects.json') `
            -Algorithm SHA256).Hash) `
        -Expected $ProjectsHash `
        -Message 'projects.json must be preserved byte-for-byte'
    Assert-Equal `
        -Actual ((Get-FileHash `
            -LiteralPath (Join-Path $installRoot 'launcher-state.json') `
            -Algorithm SHA256).Hash) `
        -Expected $StateHash `
        -Message 'launcher-state.json must be preserved byte-for-byte'

    $profile = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8
    Assert-True `
        -Condition $profile.Contains("function global:Keep-Me") `
        -Message 'pre-existing profile content must survive'
    Assert-Equal `
        -Actual ([regex]::Matches(
            $profile,
            [regex]::Escape('# >>> EL Workspace >>>')
        ).Count) `
        -Expected 1 `
        -Message 'managed profile block must occur once'
    Assert-Equal `
        -Actual ([regex]::Matches(
            $profile,
            [regex]::Escape('# <<< EL Workspace <<<')
        ).Count) `
        -Expected 1 `
        -Message 'managed profile end marker must occur once'

    Assert-True `
        -Condition (Test-Path -LiteralPath $fragmentPath -PathType Leaf) `
        -Message 'el-project sync must create test Terminal fragment'
    [void] (Get-Content -LiteralPath $fragmentPath -Raw -Encoding UTF8 |
        ConvertFrom-Json -Depth 100)

    $settings = Get-Content `
        -LiteralPath $terminalSettingsPath `
        -Raw `
        -Encoding UTF8 | ConvertFrom-Json -Depth 100
    Assert-Equal `
        -Actual $settings.customRootSetting `
        -Expected 'preserve-me' `
        -Message 'unrelated Terminal root setting must survive'
    $pwsh = @($settings.profiles.list | Where-Object {
        $_.PSObject.Properties.Name -contains 'source' -and
        $_.source -eq 'Windows.Terminal.PowershellCore'
    })
    Assert-Equal `
        -Actual $pwsh.Count `
        -Expected 1 `
        -Message 'PowerShell Core profile must stay unique'
    Assert-Equal `
        -Actual $pwsh[0].customProfileSetting `
        -Expected 'preserve-me-too' `
        -Message 'unrelated PowerShell profile setting must survive'
    Assert-True `
        -Condition (-not [string]::IsNullOrWhiteSpace([string] $pwsh[0].colorScheme)) `
        -Message 'theme profile must set colorScheme'
    Assert-True `
        -Condition (@($settings.schemes | Where-Object {
            $_.name -eq $pwsh[0].colorScheme
        }).Count -eq 1) `
        -Message 'referenced EL color scheme must exist once'
    $unrelated = @($settings.profiles.list | Where-Object {
        $_.name -eq 'Unrelated profile'
    })
    Assert-Equal `
        -Actual $unrelated[0].colorScheme `
        -Expected 'Campbell' `
        -Message 'unrelated Terminal profile must not change'

    . (Join-Path $installRoot 'profile.ps1')
    foreach ($commandName in @(
        'el',
        'el-project',
        'el-workspace',
        'elj',
        'app',
        'clean',
        'site',
        'serve',
        'g',
        'publish',
        'update-tools'
    )) {
        Assert-True `
            -Condition ($null -ne (Get-Command `
                $commandName `
                -CommandType Function `
                -ErrorAction SilentlyContinue)) `
            -Message "profile command missing: $commandName"
    }
    $versionOutput = @(el-workspace version 6>&1) -join "`n"
    Assert-True `
        -Condition ($versionOutput -match [regex]::Escape($releaseVersion)) `
        -Message 'el-workspace must work immediately after profile source'
}

[void] [IO.Directory]::CreateDirectory($testRoot)
Set-TestEnvironment
try {
    Write-Host 'TEST 1/10 · parser, irm|iex binding and deterministic release build'
    foreach ($path in @($installerPath, $buildPath, $PSCommandPath)) {
        $tokens = $null
        $errors = $null
        [void] [Management.Automation.Language.Parser]::ParseFile(
            $path,
            [ref] $tokens,
            [ref] $errors
        )
        Assert-Equal `
            -Actual @($errors).Count `
            -Expected 0 `
            -Message "PowerShell parser errors in $path"
    }
    $installerTokens = $null
    $installerErrors = $null
    $installerAst = [Management.Automation.Language.Parser]::ParseFile(
        $installerPath,
        [ref] $installerTokens,
        [ref] $installerErrors
    )
    $bindingProbe = (
        "[CmdletBinding()]`n" +
        $installerAst.ParamBlock.Extent.Text +
        "`n'BOOTSTRAP_BINDING_OK'"
    )
    $bindingOutput = @($bindingProbe | Invoke-Expression)
    Assert-Equal `
        -Actual ($bindingOutput -join '') `
        -Expected 'BOOTSTRAP_BINDING_OK' `
        -Message 'installer param block must support irm | iex execution'
    $invalidHashRejected = $false
    try {
        & $installerPath -SkipDependencies -SourceSha256 'not-a-sha256'
    }
    catch {
        $invalidHashRejected = $true
    }
    Assert-True `
        -Condition $invalidHashRejected `
        -Message 'invalid -SourceSha256 must be rejected explicitly'
    & $buildPath -OutputPath $distPath
    $archiveName = "EL-Workspace-$releaseVersion.zip"
    $archivePath = Join-Path $distPath $archiveName
    $archiveHash = (Get-FileHash `
        -LiteralPath $archivePath `
        -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True `
        -Condition (Test-Path -LiteralPath $archivePath -PathType Leaf) `
        -Message 'release archive was not created'
    Assert-True `
        -Condition (Test-Path `
            -LiteralPath (Join-Path $distPath 'SHA256SUMS.txt') `
            -PathType Leaf) `
        -Message 'SHA256SUMS.txt was not created'
    & $buildPath -OutputPath $secondDistPath
    foreach ($assetName in @(
        $archiveName,
        'install.ps1',
        'SHA256SUMS.txt'
    )) {
        Assert-Equal `
            -Actual ((Get-FileHash `
                -LiteralPath (Join-Path $distPath $assetName) `
                -Algorithm SHA256).Hash) `
            -Expected ((Get-FileHash `
                -LiteralPath (Join-Path $secondDistPath $assetName) `
                -Algorithm SHA256).Hash) `
            -Message "release asset must be deterministic: $assetName"
    }

    Write-Host 'TEST 2/10 · directory install, preservation and structural merge'
    Write-Utf8 `
        -Path $profilePath `
        -Content "function global:Keep-Me { 'kept' }`r`n"
    New-TestTerminalSettings
    [void] [IO.Directory]::CreateDirectory($installRoot)
    $projectsSource = Join-Path $repositoryRoot 'defaults\projects.json'
    $stateSource = Join-Path $repositoryRoot 'defaults\launcher-state.json'
    Write-Utf8 `
        -Path (Join-Path $installRoot 'projects.json') `
        -Content ((Get-Content $projectsSource -Raw -Encoding UTF8).TrimEnd() + "`r`n `r`n")
    Write-Utf8 `
        -Path (Join-Path $installRoot 'launcher-state.json') `
        -Content ((Get-Content $stateSource -Raw -Encoding UTF8).TrimEnd() + "`r`n `r`n")
    $projectsHash = (Get-FileHash `
        -LiteralPath (Join-Path $installRoot 'projects.json') `
        -Algorithm SHA256).Hash
    $stateHash = (Get-FileHash `
        -LiteralPath (Join-Path $installRoot 'launcher-state.json') `
        -Algorithm SHA256).Hash
    Invoke-TestInstall -Source $repositoryRoot
    Assert-InstalledState -ProjectsHash $projectsHash -StateHash $stateHash

    Write-Host 'TEST 3/10 · idempotent ZIP update with SHA-256'
    Invoke-TestInstall `
        -Source $archivePath `
        -Hash $archiveHash `
        -AsUpdate
    Assert-InstalledState -ProjectsHash $projectsHash -StateHash $stateHash

    Write-Host 'TEST 4/10 · post-swap failure rolls everything back'
    $runtimeHashBefore = (Get-FileHash `
        -LiteralPath (Join-Path $installRoot 'install.json') `
        -Algorithm SHA256).Hash
    $profileHashBefore = (Get-FileHash `
        -LiteralPath $profilePath `
        -Algorithm SHA256).Hash
    $fragmentHashBefore = (Get-FileHash `
        -LiteralPath $fragmentPath `
        -Algorithm SHA256).Hash
    $settingsHashBefore = (Get-FileHash `
        -LiteralPath $terminalSettingsPath `
        -Algorithm SHA256).Hash
    $env:EL_WORKSPACE_TEST_FAIL_AFTER_SWAP = '1'
    $failedAsExpected = $false
    try {
        Invoke-TestInstall -Source $repositoryRoot -AsUpdate
    }
    catch {
        $failedAsExpected = $true
    }
    finally {
        $env:EL_WORKSPACE_TEST_FAIL_AFTER_SWAP = $null
    }
    Assert-True -Condition $failedAsExpected -Message 'forced update must fail'
    Assert-Equal `
        -Actual ((Get-FileHash `
            -LiteralPath (Join-Path $installRoot 'install.json') `
            -Algorithm SHA256).Hash) `
        -Expected $runtimeHashBefore `
        -Message 'runtime must roll back'
    Assert-Equal `
        -Actual ((Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash) `
        -Expected $profileHashBefore `
        -Message 'profile must roll back byte-for-byte'
    Assert-Equal `
        -Actual ((Get-FileHash -LiteralPath $fragmentPath -Algorithm SHA256).Hash) `
        -Expected $fragmentHashBefore `
        -Message 'fragment must roll back byte-for-byte'
    Assert-Equal `
        -Actual ((Get-FileHash `
            -LiteralPath $terminalSettingsPath `
            -Algorithm SHA256).Hash) `
        -Expected $settingsHashBefore `
        -Message 'Terminal settings must roll back byte-for-byte'

    Write-Host 'TEST 5/10 · incorrect SHA-256 is rejected before install'
    $wrongHashRejected = $false
    try {
        Invoke-TestInstall `
            -Source $archivePath `
            -Hash ('0' * 64) `
            -AsUpdate
    }
    catch {
        $wrongHashRejected = $true
    }
    Assert-True `
        -Condition $wrongHashRejected `
        -Message 'incorrect archive SHA-256 must be rejected'
    Assert-Equal `
        -Actual ((Get-FileHash `
            -LiteralPath (Join-Path $installRoot 'install.json') `
            -Algorithm SHA256).Hash) `
        -Expected $runtimeHashBefore `
        -Message 'hash failure must not change installed runtime'

    Write-Host 'TEST 6/10 · ZIP traversal is rejected'
    $maliciousArchive = Join-Path $testRoot 'malicious.zip'
    Copy-Item -LiteralPath $archivePath -Destination $maliciousArchive
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::Open(
        $maliciousArchive,
        [IO.Compression.ZipArchiveMode]::Update
    )
    try {
        $entry = $zip.CreateEntry("EL-Workspace-$releaseVersion/../escape.txt")
        $writer = [IO.StreamWriter]::new($entry.Open())
        try {
            $writer.Write('must-not-escape')
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $zip.Dispose()
    }
    $traversalRejected = $false
    try {
        Invoke-TestInstall -Source $maliciousArchive -AsUpdate
    }
    catch {
        $traversalRejected = $true
    }
    Assert-True `
        -Condition $traversalRejected `
        -Message 'malicious ZIP must be rejected'
    Assert-True `
        -Condition (@(Get-ChildItem `
            -LiteralPath $testRoot `
            -Filter 'escape.txt' `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue).Count -eq 0) `
        -Message 'malicious ZIP must not write an escape file'

    Write-Host 'TEST 7/10 · reversed profile markers are rejected before swap'
    $validProfileBytes = [IO.File]::ReadAllBytes($profilePath)
    Write-Utf8 `
        -Path $profilePath `
        -Content (
            "# <<< EL Workspace <<<`r`n" +
            "function global:Keep-Me { 'kept' }`r`n" +
            "# >>> EL Workspace >>>`r`n"
        )
    $reversedProfileHash = (Get-FileHash `
        -LiteralPath $profilePath `
        -Algorithm SHA256).Hash
    $installedLifecycle = Join-Path $installRoot 'el-workspace.ps1'
    & $installedLifecycle doctor
    Assert-Equal `
        -Actual $global:LASTEXITCODE `
        -Expected 1 `
        -Message 'lifecycle doctor must reject reversed managed markers'
    $markerOrderRejected = $false
    try {
        Invoke-TestInstall -Source $repositoryRoot -AsUpdate
    }
    catch {
        $markerOrderRejected = $true
    }
    Assert-True `
        -Condition $markerOrderRejected `
        -Message 'reversed managed profile markers must be rejected'
    Assert-Equal `
        -Actual ((Get-FileHash `
            -LiteralPath $profilePath `
            -Algorithm SHA256).Hash) `
        -Expected $reversedProfileHash `
        -Message 'invalid profile must remain byte-for-byte unchanged'
    [IO.File]::WriteAllBytes($profilePath, $validProfileBytes)

    Write-Host 'TEST 8/10 · lifecycle test overrides cannot escape TEMP sandbox'
    $validTestRoot = $env:EL_WORKSPACE_TEST_ROOT
    $outsideTempRejected = $false
    try {
        $env:EL_WORKSPACE_TEST_ROOT = $repositoryRoot
        & $installedLifecycle version
    }
    catch {
        $outsideTempRejected = $true
    }
    finally {
        $env:EL_WORKSPACE_TEST_ROOT = $validTestRoot
    }
    Assert-True `
        -Condition $outsideTempRejected `
        -Message 'lifecycle test root outside TEMP must be rejected'

    Write-Host 'TEST 9/10 · reparse ancestor in test override is rejected'
    $junctionTarget = Join-Path $testRoot 'junction-target'
    $junctionPath = Join-Path $testRoot 'junction-profile-parent'
    [void] [IO.Directory]::CreateDirectory($junctionTarget)
    [void] (New-Item `
        -ItemType Junction `
        -Path $junctionPath `
        -Target $junctionTarget `
        -ErrorAction Stop)
    $validProfilePath = $env:EL_WORKSPACE_TEST_PROFILE
    $reparseRejected = $false
    try {
        $env:EL_WORKSPACE_TEST_PROFILE = Join-Path $junctionPath 'profile.ps1'
        Invoke-TestInstall -Source $repositoryRoot -AsUpdate
    }
    catch {
        $reparseRejected = $true
    }
    finally {
        $env:EL_WORKSPACE_TEST_PROFILE = $validProfilePath
        if (Test-Path -LiteralPath $junctionPath) {
            Remove-Item -LiteralPath $junctionPath -Force
        }
    }
    Assert-True `
        -Condition $reparseRejected `
        -Message 'reparse ancestor in test override must be rejected'
    Assert-True `
        -Condition (-not (Test-Path `
            -LiteralPath (Join-Path $junctionTarget 'profile.ps1'))) `
        -Message 'reparse rejection must happen before writing target files'

    Write-Host 'TEST 10/10 · backup, restore and uninstall stay inside sandbox'
    $registryPath = Join-Path $installRoot 'projects.json'
    $registryHash = (Get-FileHash `
        -LiteralPath $registryPath `
        -Algorithm SHA256).Hash
    & $installedLifecycle backup -Yes
    Assert-Equal `
        -Actual $global:LASTEXITCODE `
        -Expected 0 `
        -Message 'lifecycle backup must succeed'
    $backupRoot = Join-Path (Split-Path -Parent $installRoot) 'Backups'
    $workspaceBackups = @(Get-ChildItem `
        -LiteralPath $backupRoot `
        -Directory `
        -Filter 'workspace-*' | Sort-Object LastWriteTimeUtc -Descending)
    Assert-True `
        -Condition ($workspaceBackups.Count -gt 0) `
        -Message 'lifecycle backup directory must be created'
    Write-Utf8 -Path $registryPath -Content "{}`n"
    & $installedLifecycle restore $workspaceBackups[0].FullName -Yes
    Assert-Equal `
        -Actual $global:LASTEXITCODE `
        -Expected 0 `
        -Message 'lifecycle restore must succeed'
    Assert-Equal `
        -Actual ((Get-FileHash `
            -LiteralPath $registryPath `
            -Algorithm SHA256).Hash) `
        -Expected $registryHash `
        -Message 'restore must recover registry byte-for-byte'

    $validProfileBeforeTamper = [IO.File]::ReadAllBytes($profilePath)
    $tamperedProfile = (Get-Content `
        -LiteralPath $profilePath `
        -Raw `
        -Encoding UTF8).Replace(
            '$elWorkspaceProfile =',
            '# changed outside installer' + "`r`n" + '$elWorkspaceProfile ='
        )
    Write-Utf8 -Path $profilePath -Content $tamperedProfile
    & $installedLifecycle uninstall -Yes
    Assert-Equal `
        -Actual $global:LASTEXITCODE `
        -Expected 1 `
        -Message 'uninstall must reject a modified managed profile block'
    Assert-True `
        -Condition (Test-Path `
            -LiteralPath (Join-Path $installRoot 'el.ps1') `
            -PathType Leaf) `
        -Message 'profile mismatch must be rejected before runtime deletion'
    [IO.File]::WriteAllBytes($profilePath, $validProfileBeforeTamper)

    $uninstallTarget = Join-Path $testRoot 'uninstall-junction-target'
    $uninstallLink = Join-Path $installRoot 'unsafe-junction'
    [void] [IO.Directory]::CreateDirectory($uninstallTarget)
    [void] (New-Item `
        -ItemType Junction `
        -Path $uninstallLink `
        -Target $uninstallTarget `
        -ErrorAction Stop)
    & $installedLifecycle uninstall -Yes
    Assert-Equal `
        -Actual $global:LASTEXITCODE `
        -Expected 1 `
        -Message 'uninstall must reject a reparse point in runtime tree'
    Assert-True `
        -Condition (Test-Path `
            -LiteralPath (Join-Path $installRoot 'el.ps1') `
            -PathType Leaf) `
        -Message 'reparse rejection must happen before runtime deletion'
    Remove-Item -LiteralPath $uninstallLink -Force

    & $installedLifecycle uninstall -Yes
    Assert-Equal `
        -Actual $global:LASTEXITCODE `
        -Expected 0 `
        -Message 'lifecycle uninstall must succeed after safe preflight'
    Assert-True `
        -Condition (-not (Test-Path `
            -LiteralPath (Join-Path $installRoot 'el.ps1'))) `
        -Message 'uninstall must remove runtime files'
    Assert-True `
        -Condition (Test-Path -LiteralPath $registryPath -PathType Leaf) `
        -Message 'uninstall must preserve projects.json by default'
    Assert-True `
        -Condition (Test-Path `
            -LiteralPath (Join-Path $installRoot 'launcher-state.json') `
            -PathType Leaf) `
        -Message 'uninstall must preserve launcher-state.json by default'
    $profileAfterUninstall = Get-Content `
        -LiteralPath $profilePath `
        -Raw `
        -Encoding UTF8
    Assert-True `
        -Condition $profileAfterUninstall.Contains('function global:Keep-Me') `
        -Message 'uninstall must preserve unrelated profile content'
    Assert-True `
        -Condition (-not $profileAfterUninstall.Contains('# >>> EL Workspace >>>')) `
        -Message 'uninstall must remove managed profile block'
    Assert-True `
        -Condition (-not (Test-Path -LiteralPath $fragmentPath)) `
        -Message 'uninstall must remove Terminal fragment'
    Assert-True `
        -Condition (Test-Path -LiteralPath $backupRoot -PathType Container) `
        -Message 'uninstall must preserve backups by default'

    Write-Host
    Write-Host 'ALL INSTALLER TESTS PASSED' -ForegroundColor Green
}
finally {
    Restore-TestEnvironment
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        if (
            [IO.Path]::GetDirectoryName($resolved).Equals(
                $temp,
                [StringComparison]::OrdinalIgnoreCase
            ) -and
            [IO.Path]::GetFileName($resolved).StartsWith(
                'EL-Workspace-tests-',
                [StringComparison]::Ordinal
            )
        ) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
