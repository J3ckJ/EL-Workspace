[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet(
        'help',
        'version',
        'doctor',
        'update',
        'backup',
        'restore',
        'uninstall',
        'publish'
    )]
    [string] $Command = 'help',

    [Parameter(Position = 1)]
    [string] $Path,

    [switch] $Yes,
    [switch] $Online,
    [switch] $PurgeData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Version = '0.1.1'
$script:Repository = 'J3ckJ/EL-Workspace'
$script:TestMode = $env:EL_WORKSPACE_TEST_MODE -eq '1'
if ($script:TestMode) {
    foreach ($variableName in @(
        'EL_WORKSPACE_TEST_ROOT',
        'EL_WORKSPACE_TEST_PROFILE',
        'EL_WORKSPACE_TEST_FRAGMENT',
        'EL_WORKSPACE_TEST_TERMINAL_SETTINGS'
    )) {
        if ([string]::IsNullOrWhiteSpace(
            [Environment]::GetEnvironmentVariable($variableName, 'Process')
        )) {
            throw "В test mode обязательна переменная $variableName."
        }
    }
}
$script:ToolRoot = if ($script:TestMode) {
    [IO.Path]::GetFullPath($env:EL_WORKSPACE_TEST_ROOT)
}
else {
    $PSScriptRoot
}
$script:ProductRoot = Split-Path -Parent $script:ToolRoot
$script:BackupRoot = Join-Path $script:ProductRoot 'Backups'
$script:ProfilePath = if ($script:TestMode) {
    [IO.Path]::GetFullPath($env:EL_WORKSPACE_TEST_PROFILE)
}
else {
    Join-Path (
        [Environment]::GetFolderPath(
            [Environment+SpecialFolder]::MyDocuments
        )
    ) 'PowerShell\profile.ps1'
}
$script:FragmentPath = if ($script:TestMode) {
    [IO.Path]::GetFullPath($env:EL_WORKSPACE_TEST_FRAGMENT)
}
else {
    Join-Path (
        [Environment]::GetFolderPath(
            [Environment+SpecialFolder]::LocalApplicationData
        )
    ) 'Microsoft\Windows Terminal\Fragments\EL.ProjectManager\projects.json'
}
$script:ProfileBegin = '# >>> EL Workspace >>>'
$script:ProfileEnd = '# <<< EL Workspace <<<'

function Write-Info {
    param([Parameter(Mandatory)][string] $Message)
    Write-Host "  $Message" -ForegroundColor DarkGray
}

function Write-Success {
    param([Parameter(Mandatory)][string] $Message)
    Write-Host "  ✓ $Message" -ForegroundColor Green
}

function Write-Failure {
    param([Parameter(Mandatory)][string] $Message)
    Write-Host "  ✗ $Message" -ForegroundColor Red
}

function Write-Notice {
    param([Parameter(Mandatory)][string] $Message)
    Write-Host "  ! $Message" -ForegroundColor Yellow
}

function Get-ELFullPath {
    param([Parameter(Mandatory)][string] $Path)

    return [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
}

function Test-ELPathInside {
    param(
        [Parameter(Mandatory)][string] $Parent,
        [Parameter(Mandatory)][string] $Candidate,
        [switch] $AllowEqual
    )

    $parentFull = Get-ELFullPath -Path $Parent
    $candidateFull = Get-ELFullPath -Path $Candidate
    if ($AllowEqual -and $candidateFull.Equals(
        $parentFull,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        return $true
    }
    return $candidateFull.StartsWith(
        $parentFull + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Assert-NoReparseComponents {
    param(
        [Parameter(Mandatory)][string] $Path,
        [string] $Anchor
    )

    $full = [IO.Path]::GetFullPath($Path)
    $start = if ($Anchor) {
        [IO.Path]::GetFullPath($Anchor)
    }
    else {
        [IO.Path]::GetPathRoot($full)
    }
    if ([string]::IsNullOrWhiteSpace($start)) {
        throw "Не удалось определить корень пути: $Path"
    }
    if ($Anchor) {
        if (-not (Test-ELPathInside `
            -Parent $start `
            -Candidate $full `
            -AllowEqual
        )) {
            throw "Путь выходит за пределы доверенного корня: $Path"
        }
        $start = Get-ELFullPath -Path $start
    }

    $relative = [IO.Path]::GetRelativePath($start, $full)
    if (
        [IO.Path]::IsPathRooted($relative) -or
        $relative -eq '..' -or
        $relative.StartsWith('..\')
    ) {
        throw "Путь выходит за пределы доверенного корня: $Path"
    }

    $current = $start
    $segments = if ($relative -eq '.') {
        @()
    }
    else {
        @($relative.Split(
            [char[]] @('\', '/'),
            [StringSplitOptions]::RemoveEmptyEntries
        ))
    }
    foreach ($segment in @('.') + $segments) {
        if ($segment -ne '.') {
            if ($segment -in @('.', '..') -or $segment.Contains(':')) {
                throw "Недопустимый компонент пути: $segment"
            }
            $current = Join-Path $current $segment
        }
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse point не допускается в пути: $current"
            }
        }
    }
}

function Assert-TestOverrides {
    if (-not $script:TestMode) {
        return
    }

    $temporaryRoot = Get-ELFullPath -Path ([IO.Path]::GetTempPath())
    $paths = [ordered]@{
        EL_WORKSPACE_TEST_ROOT = $script:ToolRoot
        EL_WORKSPACE_TEST_PROFILE = $script:ProfilePath
        EL_WORKSPACE_TEST_FRAGMENT = $script:FragmentPath
        EL_WORKSPACE_TEST_TERMINAL_SETTINGS =
            [IO.Path]::GetFullPath($env:EL_WORKSPACE_TEST_TERMINAL_SETTINGS)
    }
    $sandboxRoot = $null
    foreach ($entry in $paths.GetEnumerator()) {
        $candidate = Get-ELFullPath -Path ([string] $entry.Value)
        if (-not (Test-ELPathInside -Parent $temporaryRoot -Candidate $candidate)) {
            throw "$($entry.Key) должна указывать внутрь системного TEMP."
        }
        $relative = [IO.Path]::GetRelativePath($temporaryRoot, $candidate)
        $segments = @($relative.Split(
            [char[]] @('\', '/'),
            [StringSplitOptions]::RemoveEmptyEntries
        ))
        if (
            $segments.Count -lt 2 -or
            $segments[0] -notmatch '^EL-Workspace-tests-[0-9a-fA-F]{32}$'
        ) {
            throw (
                "$($entry.Key) должна находиться внутри уникального " +
                'TEMP\EL-Workspace-tests-<guid>.'
            )
        }
        $candidateSandbox = Get-ELFullPath -Path (
            Join-Path $temporaryRoot $segments[0]
        )
        if ($null -eq $sandboxRoot) {
            $sandboxRoot = $candidateSandbox
        }
        elseif (-not $sandboxRoot.Equals(
            $candidateSandbox,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw 'Все test override paths должны использовать один sandbox.'
        }
    }
    if (-not (Test-Path -LiteralPath $sandboxRoot -PathType Container)) {
        throw "Test sandbox не найден: $sandboxRoot"
    }
    Assert-NoReparseComponents -Path $sandboxRoot
    foreach ($entry in $paths.GetEnumerator()) {
        Assert-NoReparseComponents `
            -Path ([string] $entry.Value) `
            -Anchor $sandboxRoot
    }
}

function Assert-PlainTree {
    param([Parameter(Mandatory)][string] $Root)

    Assert-NoReparseComponents -Path $Root
    $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer) {
        throw "Ожидался каталог: $Root"
    }
    $unsafe = @(Get-ChildItem -LiteralPath $Root -Force -Recurse |
        Where-Object {
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        })
    if ($unsafe.Count -gt 0) {
        throw "Каталог содержит reparse point: $($unsafe[0].FullName)"
    }
}

function Confirm-ELAction {
    param([Parameter(Mandatory)][string] $Prompt)

    if ($Yes) {
        return $true
    }
    if ([Console]::IsInputRedirected) {
        throw 'Для неинтерактивного запуска добавьте -Yes.'
    }
    return (Read-Host "  $Prompt [y/N]").Trim() -match '^(?i:y|yes|д|да)$'
}

function Write-AtomicBytes {
    param(
        [Parameter(Mandatory)][string] $Destination,
        [Parameter(Mandatory)][byte[]] $Bytes
    )

    Assert-NoReparseComponents -Path $Destination
    $parent = Split-Path -Parent $Destination
    [void] [IO.Directory]::CreateDirectory($parent)
    Assert-NoReparseComponents -Path $parent
    $temporary = Join-Path $parent (
        '.' + (Split-Path -Leaf $Destination) + '.' +
        [Guid]::NewGuid().ToString('N') + '.tmp'
    )
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Write-AtomicText {
    param(
        [Parameter(Mandatory)][string] $Destination,
        [Parameter(Mandatory)][string] $Content
    )

    Write-AtomicBytes `
        -Destination $Destination `
        -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($Content))
}

function Get-ManagedProfileBlock {
    $modulePath = Join-Path $script:ToolRoot 'profile.ps1'
    $literal = "'" + $modulePath.Replace("'", "''") + "'"
    return @"
$script:ProfileBegin
`$elWorkspaceProfile = $literal
if (Test-Path -LiteralPath `$elWorkspaceProfile -PathType Leaf) {
    . `$elWorkspaceProfile
}
$script:ProfileEnd
"@
}

function ConvertTo-NormalizedProfileBlock {
    param([AllowEmptyString()][string] $Value)

    $normalized = ($Value -replace "`r`n", "`n") -replace "`r", "`n"
    return $normalized.TrimEnd([char[]] @("`n"))
}

function Get-ManagedProfileState {
    param(
        [AllowEmptyString()][string] $Content,
        [string] $ExpectedBlock,
        [switch] $AllowMissing
    )

    if ($null -eq $Content) {
        $Content = ''
    }
    $beginLine = '(?m)^' + [regex]::Escape($script:ProfileBegin) + '\r?$'
    $endLine = '(?m)^' + [regex]::Escape($script:ProfileEnd) + '\r?$'
    $beginMatches = [regex]::Matches($Content, $beginLine)
    $endMatches = [regex]::Matches($Content, $endLine)
    $rawBeginCount = [regex]::Matches(
        $Content,
        [regex]::Escape($script:ProfileBegin)
    ).Count
    $rawEndCount = [regex]::Matches(
        $Content,
        [regex]::Escape($script:ProfileEnd)
    ).Count

    if ($beginMatches.Count -eq 0 -and $endMatches.Count -eq 0) {
        if (-not $AllowMissing) {
            throw 'Управляемый блок EL Workspace отсутствует в PowerShell profile.'
        }
        return [pscustomobject]@{ Present = $false; Match = $null }
    }
    if (
        $beginMatches.Count -ne 1 -or
        $endMatches.Count -ne 1 -or
        $rawBeginCount -ne 1 -or
        $rawEndCount -ne 1
    ) {
        throw 'PowerShell profile содержит повреждённые EL Workspace markers.'
    }
    if ($beginMatches[0].Index -ge $endMatches[0].Index) {
        throw 'EL Workspace markers расположены в неверном порядке.'
    }

    $blockPattern = '(?ms)^' + [regex]::Escape($script:ProfileBegin) +
        '\r?\n.*?^' + [regex]::Escape($script:ProfileEnd) + '(?=\r?$)'
    $blockMatch = [regex]::Match($Content, $blockPattern)
    if (-not $blockMatch.Success) {
        throw 'Не удалось однозначно разобрать managed profile block.'
    }
    if ($PSBoundParameters.ContainsKey('ExpectedBlock')) {
        $actual = ConvertTo-NormalizedProfileBlock -Value $blockMatch.Value
        $expected = ConvertTo-NormalizedProfileBlock -Value $ExpectedBlock
        if (-not $actual.Equals($expected, [StringComparison]::Ordinal)) {
            throw 'Managed profile block не соответствует текущей установке.'
        }
    }
    return [pscustomobject]@{ Present = $true; Match = $blockMatch }
}

function Get-TerminalSettingsPath {
    if ($script:TestMode) {
        return [IO.Path]::GetFullPath($env:EL_WORKSPACE_TEST_TERMINAL_SETTINGS)
    }
    $localData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::LocalApplicationData
    )
    foreach ($candidate in @(
        (Join-Path $localData 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $localData 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $localData 'Microsoft\Windows Terminal\settings.json')
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    return $null
}

function Get-BackupTargets {
    $themePath = Join-Path $script:ToolRoot 'themes\el-midnight.omp.json'
    $settingsPath = Get-TerminalSettingsPath
    $targets = [ordered]@{
        registry = Join-Path $script:ToolRoot 'projects.json'
        launcherState = Join-Path $script:ToolRoot 'launcher-state.json'
        profile = $script:ProfilePath
        theme = $themePath
        terminalFragment = $script:FragmentPath
        installMetadata = Join-Path $script:ToolRoot 'install.json'
    }
    if ($settingsPath) {
        $targets['terminalSettings'] = $settingsPath
    }
    return $targets
}

function Invoke-Backup {
    Assert-NoReparseComponents -Path $script:ToolRoot
    if (Test-Path -LiteralPath $script:ToolRoot) {
        $toolItem = Get-Item -LiteralPath $script:ToolRoot -Force
        if (-not $toolItem.PSIsContainer) {
            throw "Runtime root не является каталогом: $script:ToolRoot"
        }
    }
    Assert-NoReparseComponents -Path $script:BackupRoot
    [void] [IO.Directory]::CreateDirectory($script:BackupRoot)
    Assert-NoReparseComponents -Path $script:BackupRoot
    $backupRootItem = Get-Item -LiteralPath $script:BackupRoot -Force
    if (
        -not $backupRootItem.PSIsContainer -or
        ($backupRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    ) {
        throw "Небезопасный каталог backups: $script:BackupRoot"
    }
    $backupPath = Join-Path $script:BackupRoot (
        'workspace-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' +
        [Guid]::NewGuid().ToString('N').Substring(0, 8)
    )
    $filesPath = Join-Path $backupPath 'files'
    [void] [IO.Directory]::CreateDirectory($filesPath)
    $inventory = [Collections.Generic.List[object]]::new()

    foreach ($entry in (Get-BackupTargets).GetEnumerator()) {
        if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) {
            continue
        }
        Assert-NoReparseComponents -Path ([string] $entry.Value)
        $sourceItem = Get-Item -LiteralPath $entry.Value -Force
        if (
            $sourceItem.PSIsContainer -or
            ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        ) {
            throw "Backup source должен быть обычным файлом: $($entry.Value)"
        }
        $fileName = "$($entry.Key)-$(Split-Path -Leaf $entry.Value)"
        $destination = Join-Path $filesPath $fileName
        Copy-Item -LiteralPath $entry.Value -Destination $destination
        $inventory.Add([pscustomobject][ordered]@{
            key = $entry.Key
            file = "files/$fileName"
            sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    }

    $inventoryDocument = [ordered]@{
        schemaVersion = 1
        createdAt = [DateTimeOffset]::UtcNow.ToString('o')
        version = $script:Version
        files = @($inventory)
    } | ConvertTo-Json -Depth 20
    Write-AtomicText `
        -Destination (Join-Path $backupPath 'inventory.json') `
        -Content $inventoryDocument
    Write-Success "Backup создан: $backupPath"
    return $backupPath
}

function Invoke-Restore {
    if (-not $Path) {
        throw 'Укажите backup: el-workspace restore <path>'
    }
    $backupPath = [IO.Path]::GetFullPath($Path)
    Assert-NoReparseComponents -Path $backupPath
    $backupItem = Get-Item -LiteralPath $backupPath -Force
    if (-not $backupItem.PSIsContainer -or
        ($backupItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Backup должен быть обычным каталогом.'
    }
    $inventoryPath = Join-Path $backupPath 'inventory.json'
    Assert-NoReparseComponents -Path $inventoryPath -Anchor $backupPath
    $inventoryItem = Get-Item -LiteralPath $inventoryPath -Force -ErrorAction Stop
    if (
        $inventoryItem.PSIsContainer -or
        ($inventoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    ) {
        throw 'Backup inventory должен быть обычным файлом.'
    }
    $inventory = Get-Content -LiteralPath $inventoryPath -Raw -Encoding UTF8 |
        ConvertFrom-Json -Depth 30
    if ($inventory.schemaVersion -ne 1) {
        throw 'Неподдерживаемая версия backup inventory.'
    }
    $targets = Get-BackupTargets
    foreach ($file in @($inventory.files)) {
        if (-not $targets.Contains($file.key)) {
            throw "Неизвестная категория backup: $($file.key)"
        }
        if ([string]::IsNullOrWhiteSpace([string] $file.file)) {
            throw "В backup отсутствует путь файла: $($file.key)"
        }
        $source = [IO.Path]::GetFullPath((
            Join-Path $backupPath ([string] $file.file)
        ))
        if (-not (Test-ELPathInside -Parent $backupPath -Candidate $source)) {
            throw 'Файл backup выходит за пределы каталога.'
        }
        Assert-NoReparseComponents -Path $source -Anchor $backupPath
        $sourceItem = Get-Item -LiteralPath $source -Force -ErrorAction Stop
        if (
            $sourceItem.PSIsContainer -or
            ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        ) {
            throw "Файл backup должен быть обычным файлом: $($file.key)"
        }
        $actualHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $file.sha256) {
            throw "SHA-256 backup не совпадает: $($file.key)"
        }
        Assert-NoReparseComponents -Path ([string] $targets[$file.key])
    }

    Write-Host
    Write-Host '  Восстановить EL Workspace' -ForegroundColor Yellow
    Write-Info "Backup: $backupPath"
    Write-Info "Файлов: $(@($inventory.files).Count)"
    if (-not (Confirm-ELAction -Prompt 'Продолжить?')) {
        Write-Info 'Восстановление отменено.'
        return
    }
    [void] (Invoke-Backup)
    foreach ($file in @($inventory.files)) {
        $source = Join-Path $backupPath $file.file
        Write-AtomicBytes `
            -Destination ([string] $targets[$file.key]) `
            -Bytes ([IO.File]::ReadAllBytes($source))
    }
    $manager = Join-Path $script:ToolRoot 'el-project.ps1'
    if (Test-Path -LiteralPath $manager -PathType Leaf) {
        & $manager sync
        if ($LASTEXITCODE -ne 0) {
            throw 'Файлы восстановлены, но синхронизация Terminal завершилась ошибкой.'
        }
    }
    Write-Success 'EL Workspace восстановлен.'
}

function Test-PowerShellFile {
    param([Parameter(Mandatory)][string] $FilePath)

    $tokens = $null
    $errors = $null
    [void] [Management.Automation.Language.Parser]::ParseFile(
        $FilePath,
        [ref] $tokens,
        [ref] $errors
    )
    if ($errors.Count -gt 0) {
        throw "PowerShell parser: $FilePath — $($errors[0].Message)"
    }
}

function Invoke-Doctor {
    $failed = $false
    Write-Host
    Write-Host '  EL WORKSPACE · DOCTOR' -ForegroundColor Cyan
    Write-Host

    foreach ($fileName in @(
        'el.ps1',
        'el-project.ps1',
        'workspace-pane.ps1',
        'el-workspace.ps1',
        'profile.ps1',
        'projects.schema.json',
        'el-project.schema.json',
        'themes\el-midnight.omp.json',
        'themes\el-midnight.terminal.json'
    )) {
        $candidate = Join-Path $script:ToolRoot $fileName
        try {
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                throw 'файл отсутствует'
            }
            if ($candidate.EndsWith('.ps1')) {
                Test-PowerShellFile -FilePath $candidate
            }
            else {
                [void] (Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 |
                    ConvertFrom-Json -Depth 100)
            }
            Write-Success $fileName
        }
        catch {
            Write-Failure "${fileName}: $($_.Exception.Message)"
            $failed = $true
        }
    }

    foreach ($commandName in @('pwsh.exe', 'wt.exe')) {
        if (Get-Command $commandName -ErrorAction SilentlyContinue) {
            Write-Success "Команда доступна: $commandName"
        }
        else {
            Write-Failure "Команда не найдена: $commandName"
            $failed = $true
        }
    }
    foreach ($commandName in @('git.exe', 'zoxide.exe', 'fzf.exe', 'oh-my-posh.exe')) {
        if (Get-Command $commandName -ErrorAction SilentlyContinue) {
            Write-Success "Опциональная команда доступна: $commandName"
        }
        else {
            Write-Notice "Опциональная команда не найдена: $commandName"
        }
    }

    try {
        if (-not (Test-Path -LiteralPath $script:ProfilePath -PathType Leaf)) {
            throw 'PowerShell profile отсутствует.'
        }
        Assert-NoReparseComponents -Path $script:ProfilePath
        $profileContent = Get-Content `
            -LiteralPath $script:ProfilePath `
            -Raw `
            -Encoding UTF8
        [void] (Get-ManagedProfileState `
            -Content $profileContent `
            -ExpectedBlock (Get-ManagedProfileBlock))
        Write-Success 'Управляемый блок PowerShell profile корректен'
    }
    catch {
        Write-Failure "PowerShell profile: $($_.Exception.Message)"
        $failed = $true
    }

    $manager = Join-Path $script:ToolRoot 'el-project.ps1'
    if (Test-Path -LiteralPath $manager -PathType Leaf) {
        & $manager sync -Check
        if ($LASTEXITCODE -ne 0) {
            $failed = $true
        }
    }

    if ($Online) {
        try {
            $uri = "https://github.com/$script:Repository/releases/latest/download/install.ps1"
            [void] (Invoke-WebRequest -Uri $uri -Method Head -UseBasicParsing)
            Write-Success 'Release endpoint доступен'
        }
        catch {
            Write-Failure "Release endpoint недоступен: $($_.Exception.Message)"
            $failed = $true
        }
    }
    Write-Host
    if ($failed) {
        throw 'Doctor обнаружил ошибки.'
    }
    Write-Success 'EL Workspace готов к работе.'
}

function Invoke-Update {
    $installerUri = "https://github.com/$script:Repository/releases/latest/download/install.ps1"
    $temporary = Join-Path ([IO.Path]::GetTempPath()) (
        'el-workspace-install-' + [Guid]::NewGuid().ToString('N') + '.ps1'
    )
    try {
        Write-Info 'Получаю установщик из последнего GitHub Release…'
        Invoke-WebRequest -Uri $installerUri -OutFile $temporary -UseBasicParsing
        Test-PowerShellFile -FilePath $temporary
        & $temporary -Update -Yes:$Yes
        if ($LASTEXITCODE -ne 0) {
            throw "Установщик завершился с кодом $LASTEXITCODE."
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Remove-ManagedProfileBlock {
    if (-not (Test-Path -LiteralPath $script:ProfilePath -PathType Leaf)) {
        return
    }
    Assert-NoReparseComponents -Path $script:ProfilePath
    $content = Get-Content -LiteralPath $script:ProfilePath -Raw -Encoding UTF8
    $state = Get-ManagedProfileState `
        -Content $content `
        -ExpectedBlock (Get-ManagedProfileBlock) `
        -AllowMissing
    if (-not $state.Present) {
        return
    }
    $match = $state.Match
    $updated = (
        $content.Substring(0, $match.Index) +
        $content.Substring($match.Index + $match.Length)
    ).TrimEnd()
    if ($updated) {
        Write-AtomicText `
            -Destination $script:ProfilePath `
            -Content ($updated + [Environment]::NewLine)
    }
    else {
        Write-AtomicText -Destination $script:ProfilePath -Content ''
    }
}

function Assert-UninstallTargetsSafe {
    if (-not (Test-Path -LiteralPath $script:ToolRoot -PathType Container)) {
        throw "Runtime root не найден: $script:ToolRoot"
    }
    Assert-PlainTree -Root $script:ToolRoot

    if (Test-Path -LiteralPath $script:ProfilePath -PathType Leaf) {
        Assert-NoReparseComponents -Path $script:ProfilePath
        $profileContent = Get-Content `
            -LiteralPath $script:ProfilePath `
            -Raw `
            -Encoding UTF8
        [void] (Get-ManagedProfileState `
            -Content $profileContent `
            -ExpectedBlock (Get-ManagedProfileBlock) `
            -AllowMissing)
    }
    if (Test-Path -LiteralPath $script:FragmentPath) {
        Assert-NoReparseComponents -Path $script:FragmentPath
        $fragmentItem = Get-Item -LiteralPath $script:FragmentPath -Force
        if (
            $fragmentItem.PSIsContainer -or
            ($fragmentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        ) {
            throw 'Terminal fragment должен быть обычным файлом.'
        }
    }
    if ($PurgeData -and (Test-Path -LiteralPath $script:BackupRoot)) {
        Assert-PlainTree -Root $script:BackupRoot
    }
}

function Invoke-Uninstall {
    Assert-UninstallTargetsSafe
    Write-Host
    Write-Host '  Удалить EL Workspace' -ForegroundColor Yellow
    Write-Info 'Будут удалены runtime, Terminal fragment и управляемый блок profile.'
    Write-Info 'zoxide, fzf, Oh My Posh, шрифты и проекты затронуты не будут.'
    if (-not $PurgeData) {
        Write-Info 'Реестр проектов, launcher state и backups будут сохранены.'
    }
    else {
        Write-Host '  Режим -PurgeData удалит также реестр и локальное состояние.' `
            -ForegroundColor Red
    }
    if (-not (Confirm-ELAction -Prompt 'Продолжить?')) {
        Write-Info 'Удаление отменено.'
        return
    }
    [void] (Invoke-Backup)
    Remove-ManagedProfileBlock
    if (Test-Path -LiteralPath $script:FragmentPath -PathType Leaf) {
        Remove-Item -LiteralPath $script:FragmentPath -Force
    }

    $preserved = @('projects.json', 'launcher-state.json', 'backups')
    foreach ($item in @(Get-ChildItem -LiteralPath $script:ToolRoot -Force)) {
        if (-not $PurgeData -and $item.Name -in $preserved) {
            continue
        }
        if ($item.PSIsContainer) {
            $resolved = [IO.Path]::GetFullPath($item.FullName)
            $rootPrefix = [IO.Path]::GetFullPath($script:ToolRoot).TrimEnd('\') + '\'
            if (-not $resolved.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Небезопасная цель удаления: $resolved"
            }
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
        else {
            Remove-Item -LiteralPath $item.FullName -Force
        }
    }
    if ($PurgeData -and (Test-Path -LiteralPath $script:BackupRoot)) {
        Assert-PlainTree -Root $script:BackupRoot
        $backupItem = Get-Item -LiteralPath $script:BackupRoot -Force
        $resolvedBackup = [IO.Path]::GetFullPath($backupItem.FullName)
        $productPrefix = [IO.Path]::GetFullPath($script:ProductRoot).TrimEnd('\') + '\'
        if (
            -not $backupItem.PSIsContainer -or
            ($backupItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not $resolvedBackup.StartsWith(
                $productPrefix,
                [StringComparison]::OrdinalIgnoreCase
            ) -or
            (Split-Path -Leaf $resolvedBackup) -ne 'Backups'
        ) {
            throw "Небезопасный каталог backups: $resolvedBackup"
        }
        Remove-Item -LiteralPath $resolvedBackup -Recurse -Force
    }
    Write-Success 'EL Workspace удалён. Откройте новое окно PowerShell.'
}

function Invoke-Publish {
    $git = Get-Command git.exe -ErrorAction Stop
    $root = @(& $git.Source rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or $root.Count -ne 1) {
        throw 'Текущий каталог не является Git-репозиторием.'
    }
    $repositoryRoot = [IO.Path]::GetFullPath([string] $root[0])
    $changes = @(& $git.Source -C $repositoryRoot status --porcelain)
    if ($changes.Count -gt 0) {
        throw 'Перед публикацией закоммитьте изменения: рабочее дерево не чистое.'
    }
    $branch = @(& $git.Source -C $repositoryRoot branch --show-current)
    if ($branch.Count -ne 1 -or -not $branch[0]) {
        throw 'Не удалось определить текущую ветку.'
    }
    $remotes = @(& $git.Source -C $repositoryRoot remote)
    if ($remotes.Count -eq 0) {
        throw 'У репозитория нет Git remote.'
    }
    $remote = if ($remotes -contains 'origin') { 'origin' } else { $remotes[0] }
    $remoteUrl = @(& $git.Source -C $repositoryRoot remote get-url $remote)[0]

    Write-Host
    Write-Host '  Опубликовать текущую ветку' -ForegroundColor Yellow
    Write-Info "Репозиторий: $repositoryRoot"
    Write-Info "Ветка:       $($branch[0])"
    Write-Info "Remote:      $remoteUrl"
    if (-not (Confirm-ELAction -Prompt 'Выполнить git push?')) {
        Write-Info 'Публикация отменена.'
        return
    }
    & $git.Source -C $repositoryRoot push -u $remote $branch[0]
    if ($LASTEXITCODE -ne 0) {
        throw "git push завершился с кодом $LASTEXITCODE."
    }
    Write-Success "Ветка '$($branch[0])' опубликована."
}

function Show-Help {
    Write-Host @'

  EL WORKSPACE

  el-workspace version                 Показать версию
  el-workspace doctor [-Online]        Проверить установку
  el-workspace update                  Обновиться из GitHub Release
  el-workspace backup                  Сохранить настройки
  el-workspace restore <path>          Восстановить backup
  el-workspace uninstall               Удалить runtime, сохранить данные
  el-workspace uninstall -PurgeData    Полное удаление локальных данных
  el-workspace publish                 Опубликовать чистую Git-ветку

'@ -ForegroundColor White
}

Assert-TestOverrides

try {
    switch ($Command) {
        'help' { Show-Help }
        'version' { Write-Host "EL Workspace $script:Version" }
        'doctor' { Invoke-Doctor }
        'update' { Invoke-Update }
        'backup' { [void] (Invoke-Backup) }
        'restore' { Invoke-Restore }
        'uninstall' { Invoke-Uninstall }
        'publish' { Invoke-Publish }
    }
    $global:LASTEXITCODE = 0
}
catch {
    Write-Host
    Write-Failure $_.Exception.Message
    Write-Host
    $global:LASTEXITCODE = 1
}
