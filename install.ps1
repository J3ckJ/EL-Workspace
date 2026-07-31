#requires -Version 7.2

[CmdletBinding()]
param(
    [switch] $Update,
    [switch] $Yes,
    [switch] $SkipDependencies,

    [Parameter(DontShow)]
    [string] $SourcePath,

    [Parameter(DontShow)]
    [string] $SourceSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Version = '0.1.2'
$script:Repository = 'J3ckJ/EL-Workspace'
$script:ArchiveName = "EL-Workspace-$($script:Version).zip"
$script:ArchiveRootName = "EL-Workspace-$($script:Version)"
$script:ProfileBegin = '# >>> EL Workspace >>>'
$script:ProfileEnd = '# <<< EL Workspace <<<'
$script:TestMode = $env:EL_WORKSPACE_TEST_MODE -eq '1'
$script:TransactionStarted = $false
$script:ExistingInstallMoved = $false
$script:ProfileExisted = $false
$script:FragmentExisted = $false
$script:TerminalSettingsExisted = $false
$script:ProfileBytes = $null
$script:FragmentBytes = $null
$script:TerminalSettingsBytes = $null
$script:BackupPath = $null
$script:PreviousRuntimePath = $null
$script:NextRuntimePath = $null

if ($SourceSha256 -and $SourceSha256 -notmatch '^[a-fA-F0-9]{64}$') {
    throw '-SourceSha256 должен быть SHA-256 из 64 шестнадцатеричных символов.'
}

function Write-Info {
    param([Parameter(Mandatory)][string] $Message)
    Write-Host "  $Message" -ForegroundColor DarkGray
}

function Write-Success {
    param([Parameter(Mandatory)][string] $Message)
    Write-Host "  ✓ $Message" -ForegroundColor Green
}

function Write-Warn {
    param([Parameter(Mandatory)][string] $Message)
    Write-Host "  ! $Message" -ForegroundColor Yellow
}

function Get-FullPath {
    param([Parameter(Mandatory)][string] $Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
}

function Test-PathInside {
    param(
        [Parameter(Mandatory)][string] $Parent,
        [Parameter(Mandatory)][string] $Candidate,
        [switch] $AllowEqual
    )

    $parentFull = Get-FullPath -Path $Parent
    $candidateFull = Get-FullPath -Path $Candidate
    if ($AllowEqual -and $candidateFull.Equals(
        $parentFull,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        return $true
    }
    $prefix = $parentFull + [IO.Path]::DirectorySeparatorChar
    return $candidateFull.StartsWith(
        $prefix,
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
        $anchorFull = Get-FullPath -Path $start
        $candidateFull = Get-FullPath -Path $full
        if (
            -not $candidateFull.Equals(
                $anchorFull,
                [StringComparison]::OrdinalIgnoreCase
            ) -and
            -not (Test-PathInside -Parent $anchorFull -Candidate $candidateFull)
        ) {
            throw "Путь выходит за пределы доверенного корня: $Path"
        }
        $start = $anchorFull
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

function Assert-PlainItem {
    param(
        [Parameter(Mandatory)][string] $Path,
        [switch] $Directory
    )

    $pathType = if ($Directory) { 'Container' } else { 'Leaf' }
    if (-not (Test-Path -LiteralPath $Path -PathType $pathType)) {
        throw "Не найден обязательный путь: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Reparse point не допускается: $Path"
    }
    return $item
}

function Assert-TestPaths {
    if (-not $script:TestMode) {
        return
    }

    $required = [ordered]@{
        EL_WORKSPACE_TEST_INSTALL_ROOT = $env:EL_WORKSPACE_TEST_INSTALL_ROOT
        EL_WORKSPACE_TEST_PROFILE = $env:EL_WORKSPACE_TEST_PROFILE
        EL_WORKSPACE_TEST_FRAGMENT = $env:EL_WORKSPACE_TEST_FRAGMENT
        EL_WORKSPACE_TEST_TERMINAL_SETTINGS =
            $env:EL_WORKSPACE_TEST_TERMINAL_SETTINGS
    }
    foreach ($entry in $required.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace([string] $entry.Value)) {
            throw "В test mode обязательна переменная $($entry.Key)."
        }
    }

    $temporaryRoot = Get-FullPath -Path ([IO.Path]::GetTempPath())
    $sandboxRoot = $null
    foreach ($entry in $required.GetEnumerator()) {
        $candidate = Get-FullPath -Path ([string] $entry.Value)
        if (-not (Test-PathInside -Parent $temporaryRoot -Candidate $candidate)) {
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
        $candidateSandbox = Get-FullPath -Path (
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
    foreach ($entry in $required.GetEnumerator()) {
        Assert-NoReparseComponents `
            -Path ([string] $entry.Value) `
            -Anchor $sandboxRoot
    }
}

Assert-TestPaths

$script:InstallRoot = if ($script:TestMode) {
    Get-FullPath -Path $env:EL_WORKSPACE_TEST_INSTALL_ROOT
}
else {
    Get-FullPath -Path (Join-Path `
        ([Environment]::GetFolderPath(
            [Environment+SpecialFolder]::LocalApplicationData
        )) `
        'EL-System-Tools\Terminal'
    )
}
$script:ProductRoot = Split-Path -Parent $script:InstallRoot
$script:ProfilePath = if ($script:TestMode) {
    Get-FullPath -Path $env:EL_WORKSPACE_TEST_PROFILE
}
else {
    Get-FullPath -Path (Join-Path `
        ([Environment]::GetFolderPath(
            [Environment+SpecialFolder]::MyDocuments
        )) `
        'PowerShell\profile.ps1'
    )
}
$script:FragmentPath = if ($script:TestMode) {
    Get-FullPath -Path $env:EL_WORKSPACE_TEST_FRAGMENT
}
else {
    Get-FullPath -Path (Join-Path `
        ([Environment]::GetFolderPath(
            [Environment+SpecialFolder]::LocalApplicationData
        )) `
        'Microsoft\Windows Terminal\Fragments\EL.ProjectManager\projects.json'
    )
}
$script:TerminalSettingsPath = if ($script:TestMode) {
    Get-FullPath -Path $env:EL_WORKSPACE_TEST_TERMINAL_SETTINGS
}
else {
    $localData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::LocalApplicationData
    )
    @(
        (Join-Path $localData (
            'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\' +
            'LocalState\settings.json'
        )),
        (Join-Path $localData (
            'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\' +
            'LocalState\settings.json'
        )),
        (Join-Path $localData 'Microsoft\Windows Terminal\settings.json')
    ) | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    } | Select-Object -First 1
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

function Test-PowerShellFile {
    param([Parameter(Mandatory)][string] $FilePath)

    $tokens = $null
    $errors = $null
    [void] [Management.Automation.Language.Parser]::ParseFile(
        $FilePath,
        [ref] $tokens,
        [ref] $errors
    )
    if (@($errors).Count -gt 0) {
        throw "PowerShell parser: $FilePath — $($errors[0].Message)"
    }
}

function Invoke-Download {
    param(
        [Parameter(Mandatory)][Uri] $Uri,
        [Parameter(Mandatory)][string] $Destination
    )

    if ($Uri.Scheme -ne 'https' -or $Uri.UserInfo) {
        throw "Разрешены только HTTPS URL без credentials: $Uri"
    }
    $parameters = @{
        Uri = $Uri
        OutFile = $Destination
        MaximumRedirection = 5
        TimeoutSec = 300
        ErrorAction = 'Stop'
    }
    Invoke-WebRequest @parameters | Out-Null
}

function Assert-ArchiveSha256 {
    param(
        [Parameter(Mandatory)][string] $ArchivePath,
        [Parameter(Mandatory)][string] $ExpectedHash
    )

    $actualHash = (Get-FileHash `
        -LiteralPath $ArchivePath `
        -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    if (-not $actualHash.Equals(
        $ExpectedHash.ToLowerInvariant(),
        [StringComparison]::Ordinal
    )) {
        throw (
            'SHA-256 архива не совпадает. ' +
            "Ожидался $ExpectedHash, получен $actualHash."
        )
    }
}

function Assert-SafeArchive {
    param(
        [Parameter(Mandatory)][string] $ArchivePath,
        [Parameter(Mandatory)][string] $Destination
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $destinationFull = Get-FullPath -Path $Destination
    $destinationPrefix = $destinationFull + [IO.Path]::DirectorySeparatorChar
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $entryCount = 0
    [long] $expandedBytes = 0
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in $archive.Entries) {
            $entryCount += 1
            if ($entryCount -gt 1000) {
                throw 'В release archive слишком много записей.'
            }
            $entryName = $entry.FullName.Replace('\', '/')
            if (
                [string]::IsNullOrWhiteSpace($entryName) -or
                $entryName.StartsWith('/') -or
                $entryName.Contains(':') -or
                $entryName.Contains([char] 0)
            ) {
                throw "Небезопасное имя ZIP entry: $($entry.FullName)"
            }
            $segments = @($entryName.Split('/') | Where-Object { $_ -ne '' })
            if (
                $segments.Count -eq 0 -or
                $segments[0] -ne $script:ArchiveRootName -or
                @($segments | Where-Object { $_ -in @('.', '..') }).Count -gt 0
            ) {
                throw "ZIP entry выходит за ожидаемый release root: $entryName"
            }

            $relative = $segments -join [IO.Path]::DirectorySeparatorChar
            $target = [IO.Path]::GetFullPath((Join-Path $destinationFull $relative))
            if (-not $target.StartsWith(
                $destinationPrefix,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                throw "ZIP entry выходит из staging: $entryName"
            }
            if (-not $seen.Add($target.TrimEnd('\', '/'))) {
                throw "ZIP содержит дублирующуюся цель: $entryName"
            }

            $unixMode = ($entry.ExternalAttributes -shr 16) -band 0xFFFF
            if (($unixMode -band 0xF000) -eq 0xA000) {
                throw "Symlink не допускается в release archive: $entryName"
            }
            $windowsAttributes = $entry.ExternalAttributes -band 0xFFFF
            if (
                ($windowsAttributes -band [int] [IO.FileAttributes]::ReparsePoint) -ne 0
            ) {
                throw "Reparse point не допускается в release archive: $entryName"
            }

            $expandedBytes += $entry.Length
            if ($expandedBytes -gt 128MB) {
                throw 'Распакованный release archive превышает 128 MB.'
            }
            if ($entry.Length -gt 16MB) {
                throw "Неожиданно крупный файл в release archive: $entryName"
            }
        }
    }
    finally {
        $archive.Dispose()
    }
    if ($entryCount -eq 0) {
        throw 'Release archive пуст.'
    }
}

function Expand-VerifiedArchive {
    param(
        [Parameter(Mandatory)][string] $ArchivePath,
        [Parameter(Mandatory)][string] $Destination
    )

    Assert-SafeArchive -ArchivePath $ArchivePath -Destination $Destination
    [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $Destination)
    $root = Join-Path $Destination $script:ArchiveRootName
    [void] (Assert-PlainItem -Path $root -Directory)
    $unsafe = @(Get-ChildItem -LiteralPath $root -Force -Recurse |
        Where-Object {
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        })
    if ($unsafe.Count -gt 0) {
        throw 'Распакованный release содержит reparse point.'
    }
    return $root
}

function Get-RemotePayload {
    param([Parameter(Mandatory)][string] $TemporaryRoot)

    $base = "https://github.com/$script:Repository/releases/latest/download"
    $archivePath = Join-Path $TemporaryRoot $script:ArchiveName
    $checksumsPath = Join-Path $TemporaryRoot 'SHA256SUMS.txt'
    Write-Info "Загружаю EL Workspace $script:Version из GitHub Release…"
    Invoke-Download `
        -Uri ([Uri] "$base/$($script:ArchiveName)") `
        -Destination $archivePath
    Invoke-Download `
        -Uri ([Uri] "$base/SHA256SUMS.txt") `
        -Destination $checksumsPath

    $checksumText = Get-Content -LiteralPath $checksumsPath -Raw -Encoding UTF8
    $escapedName = [regex]::Escape($script:ArchiveName)
    $matches = [regex]::Matches(
        $checksumText,
        "(?im)^([0-9a-f]{64})\s+\*?$escapedName\s*$"
    )
    if ($matches.Count -ne 1) {
        throw "SHA256SUMS.txt не содержит ровно одну запись для $script:ArchiveName."
    }
    Assert-ArchiveSha256 `
        -ArchivePath $archivePath `
        -ExpectedHash $matches[0].Groups[1].Value

    $extractRoot = Join-Path $TemporaryRoot 'release'
    [void] [IO.Directory]::CreateDirectory($extractRoot)
    return Expand-VerifiedArchive `
        -ArchivePath $archivePath `
        -Destination $extractRoot
}

function Get-LocalPayload {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $TemporaryRoot
    )

    $resolvedPath = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    if ($resolvedPath.Provider.Name -ne 'FileSystem') {
        throw 'SourcePath должен использовать FileSystem provider.'
    }
    $resolved = $resolvedPath.ProviderPath
    $item = Get-Item -LiteralPath $resolved -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'SourcePath не может быть reparse point.'
    }
    if ($item.PSIsContainer) {
        if ($SourceSha256) {
            throw '-SourceSha256 применяется только к ZIP-файлу.'
        }
        Write-Info "Использую локальный source tree: $resolved"
        return Get-FullPath -Path $resolved
    }
    if (-not $item.Name.EndsWith('.zip', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'SourcePath должен быть каталогом репозитория или ZIP-файлом.'
    }
    if (-not $SourceSha256 -and -not $script:TestMode) {
        throw 'Для локального ZIP вне test mode обязателен -SourceSha256.'
    }
    if ($SourceSha256) {
        Assert-ArchiveSha256 -ArchivePath $resolved -ExpectedHash $SourceSha256
    }
    $extractRoot = Join-Path $TemporaryRoot 'local-release'
    [void] [IO.Directory]::CreateDirectory($extractRoot)
    return Expand-VerifiedArchive `
        -ArchivePath $resolved `
        -Destination $extractRoot
}

function Assert-SafeSourceTree {
    param([Parameter(Mandatory)][string] $Root)

    [void] (Assert-PlainItem -Path $Root -Directory)
    $count = 0
    [long] $totalBytes = 0
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Force -Recurse)) {
        $count += 1
        if ($count -gt 2000) {
            throw "Слишком много элементов в payload: $Root"
        }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Payload содержит reparse point: $($item.FullName)"
        }
        if (-not $item.PSIsContainer) {
            if ($item.Length -gt 16MB) {
                throw "Payload содержит слишком крупный файл: $($item.FullName)"
            }
            $totalBytes += $item.Length
            if ($totalBytes -gt 128MB) {
                throw 'Payload превышает 128 MB.'
            }
        }
    }
}

function Copy-SafeTree {
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Destination
    )

    Assert-SafeSourceTree -Root $Source
    [void] [IO.Directory]::CreateDirectory($Destination)
    $sourceFull = Get-FullPath -Path $Source
    foreach ($item in @(Get-ChildItem -LiteralPath $sourceFull -Force -Recurse)) {
        $relative = [IO.Path]::GetRelativePath($sourceFull, $item.FullName)
        if (
            [IO.Path]::IsPathRooted($relative) -or
            $relative -eq '..' -or
            $relative.StartsWith('..\')
        ) {
            throw "Payload path выходит из source root: $($item.FullName)"
        }
        $target = [IO.Path]::GetFullPath((Join-Path $Destination $relative))
        if (-not (Test-PathInside -Parent $Destination -Candidate $target)) {
            throw "Payload path выходит из destination root: $relative"
        }
        if ($item.PSIsContainer) {
            [void] [IO.Directory]::CreateDirectory($target)
        }
        else {
            [void] [IO.Directory]::CreateDirectory((Split-Path -Parent $target))
            Copy-Item -LiteralPath $item.FullName -Destination $target
        }
    }
}

function Assert-Payload {
    param([Parameter(Mandatory)][string] $Root)

    $terminalRoot = Join-Path $Root 'src\Terminal'
    $defaultsRoot = Join-Path $Root 'defaults'
    $themesRoot = Join-Path $Root 'themes'
    foreach ($directory in @($terminalRoot, $defaultsRoot, $themesRoot)) {
        [void] (Assert-PlainItem -Path $directory -Directory)
    }

    $requiredPowerShell = @(
        'el.ps1',
        'el-project.ps1',
        'workspace-pane.ps1',
        'el-workspace.ps1',
        'profile.ps1'
    )
    foreach ($fileName in $requiredPowerShell) {
        $path = Join-Path $terminalRoot $fileName
        [void] (Assert-PlainItem -Path $path)
        Test-PowerShellFile -FilePath $path
    }
    foreach ($relativePath in @(
        'src\Terminal\projects.schema.json',
        'src\Terminal\el-project.schema.json',
        'defaults\projects.json',
        'defaults\launcher-state.json',
        'themes\el-midnight.omp.json',
        'themes\el-midnight.terminal.json'
    )) {
        $path = Join-Path $Root $relativePath
        [void] (Assert-PlainItem -Path $path)
        try {
            [void] (Get-Content -LiteralPath $path -Raw -Encoding UTF8 |
                ConvertFrom-Json -Depth 100)
        }
        catch {
            throw "Некорректный JSON $relativePath — $($_.Exception.Message)"
        }
    }
    Assert-SafeSourceTree -Root $terminalRoot
    Assert-SafeSourceTree -Root $defaultsRoot
    Assert-SafeSourceTree -Root $themesRoot
}

function New-Backup {
    $backupRoot = Join-Path $script:ProductRoot 'Backups'
    Assert-NoReparseComponents -Path $script:ProductRoot
    Assert-NoReparseComponents -Path $backupRoot
    [void] [IO.Directory]::CreateDirectory($backupRoot)
    Assert-NoReparseComponents -Path $backupRoot
    [void] (Assert-PlainItem -Path $backupRoot -Directory)
    $script:BackupPath = Join-Path $backupRoot (
        'installer-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' +
        [Guid]::NewGuid().ToString('N').Substring(0, 8)
    )
    [void] [IO.Directory]::CreateDirectory($script:BackupPath)

    $targets = [ordered]@{
        profile = $script:ProfilePath
        fragment = $script:FragmentPath
    }
    if ($script:TerminalSettingsPath) {
        $targets['terminalSettings'] = $script:TerminalSettingsPath
    }
    foreach ($fileName in @('projects.json', 'launcher-state.json', 'install.json')) {
        $targets[$fileName] = Join-Path $script:InstallRoot $fileName
    }

    $inventory = [Collections.Generic.List[object]]::new()
    foreach ($entry in $targets.GetEnumerator()) {
        if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) {
            continue
        }
        Assert-NoReparseComponents -Path ([string] $entry.Value)
        [void] (Assert-PlainItem -Path $entry.Value)
        $backupName = "$($entry.Key)-$(Split-Path -Leaf $entry.Value)"
        $destination = Join-Path $script:BackupPath $backupName
        Copy-Item -LiteralPath $entry.Value -Destination $destination
        $inventory.Add([pscustomobject][ordered]@{
            key = $entry.Key
            source = [string] $entry.Value
            file = $backupName
            sha256 = (Get-FileHash `
                -LiteralPath $destination `
                -Algorithm SHA256
            ).Hash.ToLowerInvariant()
        })
    }
    $document = [ordered]@{
        schemaVersion = 1
        version = $script:Version
        createdAt = [DateTimeOffset]::UtcNow.ToString('o')
        files = @($inventory)
    } | ConvertTo-Json -Depth 20
    Write-AtomicText `
        -Destination (Join-Path $script:BackupPath 'inventory.json') `
        -Content ($document + [Environment]::NewLine)
    Write-Info "Backup: $script:BackupPath"
}

function Copy-PreservedData {
    param(
        [Parameter(Mandatory)][string] $PayloadRoot,
        [Parameter(Mandatory)][string] $DestinationRoot
    )

    foreach ($fileName in @('projects.json', 'launcher-state.json')) {
        $existing = Join-Path $script:InstallRoot $fileName
        $default = Join-Path (Join-Path $PayloadRoot 'defaults') $fileName
        $source = if (Test-Path -LiteralPath $existing -PathType Leaf) {
            [void] (Assert-PlainItem -Path $existing)
            $existing
        }
        else {
            $default
        }
        Copy-Item `
            -LiteralPath $source `
            -Destination (Join-Path $DestinationRoot $fileName)
    }
}

function New-RuntimeStaging {
    param([Parameter(Mandatory)][string] $PayloadRoot)

    Assert-NoReparseComponents -Path $script:ProductRoot
    [void] [IO.Directory]::CreateDirectory($script:ProductRoot)
    Assert-NoReparseComponents -Path $script:ProductRoot
    [void] (Assert-PlainItem -Path $script:ProductRoot -Directory)
    if (Test-Path -LiteralPath $script:InstallRoot) {
        [void] (Assert-PlainItem -Path $script:InstallRoot -Directory)
    }
    $script:NextRuntimePath = Join-Path $script:ProductRoot (
        '.Terminal.install-' + [Guid]::NewGuid().ToString('N')
    )
    if (Test-Path -LiteralPath $script:NextRuntimePath) {
        throw "Transaction staging уже существует: $script:NextRuntimePath"
    }
    [void] [IO.Directory]::CreateDirectory($script:NextRuntimePath)

    Copy-SafeTree `
        -Source (Join-Path $PayloadRoot 'src\Terminal') `
        -Destination $script:NextRuntimePath
    Copy-SafeTree `
        -Source (Join-Path $PayloadRoot 'themes') `
        -Destination (Join-Path $script:NextRuntimePath 'themes')
    Copy-PreservedData `
        -PayloadRoot $PayloadRoot `
        -DestinationRoot $script:NextRuntimePath

    $metadata = [ordered]@{
        schemaVersion = 1
        version = $script:Version
        installedAt = [DateTimeOffset]::UtcNow.ToString('o')
        repository = "https://github.com/$script:Repository"
        mode = if ($Update) { 'update' } else { 'install' }
    } | ConvertTo-Json -Depth 10
    Write-AtomicText `
        -Destination (Join-Path $script:NextRuntimePath 'install.json') `
        -Content ($metadata + [Environment]::NewLine)
}

function Get-ManagedProfileBlock {
    $modulePath = Join-Path $script:InstallRoot 'profile.ps1'
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

function Set-ManagedProfileBlock {
    $content = if (Test-Path -LiteralPath $script:ProfilePath -PathType Leaf) {
        Get-Content -LiteralPath $script:ProfilePath -Raw
    }
    else {
        ''
    }
    $state = Get-ManagedProfileState -Content $content -AllowMissing
    $block = Get-ManagedProfileBlock
    if ($state.Present) {
        $match = $state.Match
        $updated = $content.Substring(0, $match.Index) +
            $block +
            $content.Substring($match.Index + $match.Length)
    }
    else {
        $prefix = $content.TrimEnd("`r", "`n")
        $updated = if ($prefix) {
            $prefix + "`r`n`r`n" + $block + "`r`n"
        }
        else {
            $block + "`r`n"
        }
    }
    Write-AtomicText -Destination $script:ProfilePath -Content $updated
    $written = Get-Content -LiteralPath $script:ProfilePath -Raw -Encoding UTF8
    [void] (Get-ManagedProfileState `
        -Content $written `
        -ExpectedBlock $block)
}

function Assert-ProfileCanBeManaged {
    if (-not (Test-Path -LiteralPath $script:ProfilePath)) {
        return
    }
    Assert-NoReparseComponents -Path $script:ProfilePath
    $profileItem = Get-Item -LiteralPath $script:ProfilePath -Force
    if (
        $profileItem.PSIsContainer -or
        ($profileItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    ) {
        throw 'PowerShell profile должен быть обычным файлом.'
    }
    $content = Get-Content `
        -LiteralPath $script:ProfilePath `
        -Raw `
        -Encoding UTF8
    [void] (Get-ManagedProfileState -Content $content -AllowMissing)
}

function Merge-ObjectProperties {
    param(
        [Parameter(Mandatory)] $Target,
        [Parameter(Mandatory)] $Source,
        [string[]] $Excluded = @()
    )

    foreach ($property in $Source.PSObject.Properties) {
        if ($property.Name -in $Excluded) {
            continue
        }
        $targetProperty = $Target.PSObject.Properties[$property.Name]
        $sourceIsObject = $null -ne $property.Value -and
            $property.Value -is [pscustomobject]
        $targetIsObject = $null -ne $targetProperty -and
            $null -ne $targetProperty.Value -and
            $targetProperty.Value -is [pscustomobject]
        if ($sourceIsObject -and $targetIsObject) {
            Merge-ObjectProperties `
                -Target $targetProperty.Value `
                -Source $property.Value
        }
        elseif ($targetProperty) {
            $targetProperty.Value = $property.Value
        }
        else {
            $Target | Add-Member `
                -NotePropertyName $property.Name `
                -NotePropertyValue $property.Value
        }
    }
}

function Set-TerminalTheme {
    if (-not $script:TerminalSettingsPath) {
        Write-Warn 'Windows Terminal settings не найдены; theme merge пропущен.'
        return
    }
    if (-not (Test-Path -LiteralPath $script:TerminalSettingsPath -PathType Leaf)) {
        if ($script:TestMode) {
            throw "Test Terminal settings не найден: $script:TerminalSettingsPath"
        }
        Write-Warn 'Windows Terminal settings не найдены; theme merge пропущен.'
        return
    }

    $themePath = Join-Path `
        $script:InstallRoot `
        'themes\el-midnight.terminal.json'
    $theme = Get-Content -LiteralPath $themePath -Raw -Encoding UTF8 |
        ConvertFrom-Json -Depth 100
    $themeProperties = @($theme.PSObject.Properties.Name)
    if (
        'schemaVersion' -notin $themeProperties -or
        'scheme' -notin $themeProperties -or
        'profile' -notin $themeProperties -or
        $theme.schemaVersion -ne 1 -or
        -not $theme.scheme -or
        -not $theme.profile -or
        $theme.scheme.PSObject.Properties.Name -notcontains 'name' -or
        -not $theme.scheme.name
    ) {
        throw 'el-midnight.terminal.json имеет неподдерживаемый формат.'
    }

    $settings = Get-Content `
        -LiteralPath $script:TerminalSettingsPath `
        -Raw `
        -Encoding UTF8 | ConvertFrom-Json -Depth 100
    if (
        $settings.PSObject.Properties.Name -notcontains 'profiles' -or
        -not $settings.profiles -or
        $settings.profiles.PSObject.Properties.Name -notcontains 'list' -or
        -not $settings.profiles.list
    ) {
        throw 'Windows Terminal settings не содержит profiles.list.'
    }

    $powerShellProfiles = @($settings.profiles.list | Where-Object {
        ($_.PSObject.Properties.Name -contains 'source' -and
            $_.source -eq 'Windows.Terminal.PowershellCore') -or
        ($_.PSObject.Properties.Name -contains 'commandline' -and
            [string] $_.commandline -match '(?i)(^|[\\/])pwsh(?:\.exe)?(?:\s|$)')
    })
    $standardPowerShellGuid = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
    if ($powerShellProfiles.Count -eq 0) {
        $newProfile = [pscustomobject][ordered]@{
            guid = $standardPowerShellGuid
            name = 'PowerShell'
            source = 'Windows.Terminal.PowershellCore'
            hidden = $false
        }
        $settings.profiles.list = @($settings.profiles.list) + @($newProfile)
        $powerShellProfiles = @($newProfile)
    }
    elseif ($powerShellProfiles.Count -gt 1) {
        $standardProfiles = @($powerShellProfiles | Where-Object {
            $_.PSObject.Properties.Name -contains 'guid' -and
            [string] $_.guid -eq $standardPowerShellGuid
        })
        if ($standardProfiles.Count -ne 1) {
            throw (
                'Найдено несколько PowerShell Core profiles, но невозможно ' +
                'однозначно выбрать стандартный.'
            )
        }
        $powerShellProfiles = $standardProfiles
    }

    $schemes = @()
    if ($settings.PSObject.Properties.Name -contains 'schemes') {
        $schemes = @($settings.schemes)
    }
    $matchingScheme = @($schemes | Where-Object {
        $_.name -eq $theme.scheme.name
    })
    if ($matchingScheme.Count -gt 1) {
        throw "Windows Terminal содержит дубли scheme '$($theme.scheme.name)'."
    }
    if ($matchingScheme.Count -eq 1) {
        Merge-ObjectProperties -Target $matchingScheme[0] -Source $theme.scheme
    }
    else {
        $schemes += $theme.scheme
    }
    if ($settings.PSObject.Properties.Name -contains 'schemes') {
        $settings.schemes = $schemes
    }
    else {
        $settings | Add-Member -NotePropertyName schemes -NotePropertyValue $schemes
    }

    Merge-ObjectProperties `
        -Target $powerShellProfiles[0] `
        -Source $theme.profile `
        -Excluded @('guid', 'source', 'commandline', 'icon')

    $json = $settings | ConvertTo-Json -Depth 100
    [void] ($json | ConvertFrom-Json -Depth 100)
    Write-AtomicText `
        -Destination $script:TerminalSettingsPath `
        -Content ($json + [Environment]::NewLine)
    Write-Success 'Windows Terminal theme объединена с текущими settings'
}

function Invoke-ProjectSync {
    $manager = Join-Path $script:InstallRoot 'el-project.ps1'
    & $manager sync
    if ($LASTEXITCODE -ne 0) {
        throw "el-project sync завершился с кодом $LASTEXITCODE."
    }
    if (-not (Test-Path -LiteralPath $script:FragmentPath -PathType Leaf)) {
        throw "el-project sync не создал Terminal fragment: $script:FragmentPath"
    }
}

function Invoke-InstallDoctor {
    foreach ($fileName in @(
        'el.ps1',
        'el-project.ps1',
        'workspace-pane.ps1',
        'el-workspace.ps1',
        'profile.ps1'
    )) {
        Test-PowerShellFile -FilePath (Join-Path $script:InstallRoot $fileName)
    }
    foreach ($fileName in @(
        'projects.json',
        'launcher-state.json',
        'projects.schema.json',
        'el-project.schema.json',
        'install.json'
    )) {
        [void] (Get-Content `
            -LiteralPath (Join-Path $script:InstallRoot $fileName) `
            -Raw `
            -Encoding UTF8 | ConvertFrom-Json -Depth 100)
    }

    $profileText = Get-Content `
        -LiteralPath $script:ProfilePath `
        -Raw `
        -Encoding UTF8
    [void] (Get-ManagedProfileState `
        -Content $profileText `
        -ExpectedBlock (Get-ManagedProfileBlock))

    & (Join-Path $script:InstallRoot 'el-project.ps1') sync -Check
    if ($LASTEXITCODE -ne 0) {
        throw "el-project sync -Check завершился с кодом $LASTEXITCODE."
    }
}

function Refresh-ProcessPath {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $env:Path = @($userPath, $machinePath) | Where-Object { $_ } |
        Join-String -Separator ';'
}

function Install-WingetDependency {
    param(
        [Parameter(Mandatory)][string] $CommandName,
        [Parameter(Mandatory)][string] $PackageId,
        [Parameter(Mandatory)][string] $DisplayName
    )

    if (Get-Command $CommandName -ErrorAction SilentlyContinue) {
        Write-Success "$DisplayName уже доступен"
        return $true
    }
    if ($SkipDependencies -or $script:TestMode) {
        Write-Warn "$DisplayName не найден; dependency bootstrap пропущен."
        return $false
    }
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $winget) {
        Write-Warn "winget не найден; установите $DisplayName вручную."
        return $false
    }

    Write-Info "Устанавливаю $DisplayName для текущего пользователя…"
    & $winget.Source install `
        --id $PackageId `
        --exact `
        --scope user `
        --silent `
        --accept-package-agreements `
        --accept-source-agreements `
        --disable-interactivity | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "winget не смог установить $DisplayName (код $LASTEXITCODE)."
        return $false
    }
    Refresh-ProcessPath
    if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
        Write-Warn "$DisplayName установлен, но появится в PATH после нового терминала."
    }
    else {
        Write-Success "$DisplayName установлен"
    }
    return $true
}

function Install-OptionalDependencies {
    Write-Host
    Write-Host '  ЗАВИСИМОСТИ' -ForegroundColor Cyan
    [void] (Install-WingetDependency `
        -CommandName 'zoxide.exe' `
        -PackageId 'ajeetdsouza.zoxide' `
        -DisplayName 'zoxide')
    [void] (Install-WingetDependency `
        -CommandName 'fzf.exe' `
        -PackageId 'junegunn.fzf' `
        -DisplayName 'fzf')
    $poshReady = Install-WingetDependency `
        -CommandName 'oh-my-posh.exe' `
        -PackageId 'JanDeDobbeleer.OhMyPosh' `
        -DisplayName 'Oh My Posh'

    if ($poshReady -and -not $SkipDependencies -and -not $script:TestMode) {
        $fontsKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
        $fontInstalled = $false
        if (Test-Path -LiteralPath $fontsKey) {
            $fontInstalled = @(
                (Get-ItemProperty -LiteralPath $fontsKey).PSObject.Properties |
                    Where-Object { $_.Name -match '(?i)CaskaydiaCove' }
            ).Count -gt 0
        }
        if (-not $fontInstalled) {
            $posh = Get-Command oh-my-posh.exe -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($posh) {
                Write-Info 'Устанавливаю CaskaydiaCove Nerd Font без TUI…'
                & $posh.Source font install CaskaydiaCove --headless | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    Write-Warn (
                        'Nerd Font не установился автоматически; ' +
                        'это не мешает работе EL Workspace.'
                    )
                }
                else {
                    Write-Success 'CaskaydiaCove Nerd Font установлен'
                }
            }
        }
        else {
            Write-Success 'CaskaydiaCove Nerd Font уже установлен'
        }
    }
}

function Save-TransactionState {
    $script:ProfileExisted = Test-Path `
        -LiteralPath $script:ProfilePath `
        -PathType Leaf
    $script:FragmentExisted = Test-Path `
        -LiteralPath $script:FragmentPath `
        -PathType Leaf
    $script:TerminalSettingsExisted = [bool] $script:TerminalSettingsPath -and
        (Test-Path -LiteralPath $script:TerminalSettingsPath -PathType Leaf)
    if ($script:ProfileExisted) {
        [void] (Assert-PlainItem -Path $script:ProfilePath)
        $script:ProfileBytes = [IO.File]::ReadAllBytes($script:ProfilePath)
    }
    if ($script:FragmentExisted) {
        [void] (Assert-PlainItem -Path $script:FragmentPath)
        $script:FragmentBytes = [IO.File]::ReadAllBytes($script:FragmentPath)
    }
    if ($script:TerminalSettingsExisted) {
        [void] (Assert-PlainItem -Path $script:TerminalSettingsPath)
        $script:TerminalSettingsBytes = [IO.File]::ReadAllBytes(
            $script:TerminalSettingsPath
        )
    }
}

function Restore-FileState {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][bool] $Existed,
        [AllowNull()][byte[]] $Bytes
    )

    if ($Existed) {
        Write-AtomicBytes -Destination $Path -Bytes $Bytes
    }
    elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Remove-SafeRuntimeTree {
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    if (-not (Test-PathInside -Parent $script:ProductRoot -Candidate $Path)) {
        throw "Отказ от удаления небезопасной runtime path: $Path"
    }
    Assert-NoReparseComponents -Path $Path -Anchor $script:ProductRoot
    $unsafe = @(Get-ChildItem -LiteralPath $Path -Force -Recurse |
        Where-Object {
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        })
    if ($unsafe.Count -gt 0) {
        throw "Runtime tree содержит reparse point: $($unsafe[0].FullName)"
    }
    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Undo-Transaction {
    if (-not $script:TransactionStarted) {
        return
    }
    Write-Warn 'Установка не завершилась; восстанавливаю предыдущее состояние…'

    Restore-FileState `
        -Path $script:ProfilePath `
        -Existed $script:ProfileExisted `
        -Bytes $script:ProfileBytes
    Restore-FileState `
        -Path $script:FragmentPath `
        -Existed $script:FragmentExisted `
        -Bytes $script:FragmentBytes
    if ($script:TerminalSettingsPath) {
        Restore-FileState `
            -Path $script:TerminalSettingsPath `
            -Existed $script:TerminalSettingsExisted `
            -Bytes $script:TerminalSettingsBytes
    }

    if (Test-Path -LiteralPath $script:InstallRoot) {
        Remove-SafeRuntimeTree -Path $script:InstallRoot
    }
    if (
        $script:ExistingInstallMoved -and
        (Test-Path -LiteralPath $script:PreviousRuntimePath -PathType Container)
    ) {
        Move-Item `
            -LiteralPath $script:PreviousRuntimePath `
            -Destination $script:InstallRoot
    }
    if (
        $script:NextRuntimePath -and
        (Test-Path -LiteralPath $script:NextRuntimePath)
    ) {
        Remove-SafeRuntimeTree -Path $script:NextRuntimePath
    }
    Write-Success 'Предыдущее состояние восстановлено'
}

function Complete-RuntimeSwap {
    Save-TransactionState
    New-Backup
    $script:PreviousRuntimePath = Join-Path `
        $script:BackupPath `
        'previous-runtime'
    $script:TransactionStarted = $true

    if (Test-Path -LiteralPath $script:InstallRoot) {
        Assert-NoReparseComponents -Path $script:InstallRoot
        [void] (Assert-PlainItem -Path $script:InstallRoot -Directory)
        Move-Item `
            -LiteralPath $script:InstallRoot `
            -Destination $script:PreviousRuntimePath
        $script:ExistingInstallMoved = $true
    }
    Move-Item `
        -LiteralPath $script:NextRuntimePath `
        -Destination $script:InstallRoot
    $script:NextRuntimePath = $null

    Set-ManagedProfileBlock
    Set-TerminalTheme
    Invoke-ProjectSync
    if (
        $script:TestMode -and
        $env:EL_WORKSPACE_TEST_FAIL_AFTER_SWAP -eq '1'
    ) {
        throw 'Запрошена тестовая ошибка после runtime swap.'
    }
    Invoke-InstallDoctor
    $script:TransactionStarted = $false
}

function Remove-SafeTemporaryRoot {
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $full = Get-FullPath -Path $Path
    $temporary = Get-FullPath -Path ([IO.Path]::GetTempPath())
    $leaf = Split-Path -Leaf $full
    if (
        -not (Test-PathInside -Parent $temporary -Candidate $full) -or
        -not $leaf.StartsWith('EL-Workspace-', [StringComparison]::Ordinal)
    ) {
        throw "Отказ от удаления небезопасного temp path: $full"
    }
    Assert-NoReparseComponents -Path $full -Anchor $temporary
    $unsafe = @(Get-ChildItem -LiteralPath $full -Force -Recurse |
        Where-Object {
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        })
    if ($unsafe.Count -gt 0) {
        throw "Temp tree содержит reparse point: $($unsafe[0].FullName)"
    }
    Remove-Item -LiteralPath $full -Recurse -Force
}

if (-not $IsWindows) {
    throw 'Этот installer предназначен для Windows.'
}
if (
    $PSVersionTable.PSEdition -ne 'Core' -or
    $PSVersionTable.PSVersion -lt [Version] '7.2'
) {
    throw 'EL Workspace требует PowerShell 7.2 или новее (pwsh).'
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'EL-Workspace-install-' + [Guid]::NewGuid().ToString('N')
)
[void] [IO.Directory]::CreateDirectory($temporaryRoot)

try {
    Write-Host
    Write-Host '  ╭─ EL WORKSPACE' -ForegroundColor Cyan
    $modeLabel = if ($Update) {
        '  │  Безопасное обновление'
    }
    else {
        '  │  Установка для текущего пользователя'
    }
    Write-Host $modeLabel -ForegroundColor White
    Write-Host '  ╰────────────────────────' -ForegroundColor DarkGray
    Write-Host

    Install-OptionalDependencies
    $payloadRoot = if ($SourcePath) {
        Get-LocalPayload -Path $SourcePath -TemporaryRoot $temporaryRoot
    }
    else {
        Get-RemotePayload -TemporaryRoot $temporaryRoot
    }
    Assert-Payload -Root $payloadRoot
    Write-Success 'Payload и PowerShell/JSON синтаксис проверены'
    Assert-ProfileCanBeManaged

    New-RuntimeStaging -PayloadRoot $payloadRoot
    Complete-RuntimeSwap

    if (-not $script:TestMode) {
        . (Join-Path $script:InstallRoot 'profile.ps1')
    }

    Write-Host
    Write-Success "EL Workspace $script:Version готов"
    Write-Info 'Команда запуска: el'
    Write-Info 'Проверка:        el-workspace doctor'
    Write-Info 'Откройте новое окно PowerShell, чтобы применить весь стиль.'
    Write-Host
}
catch {
    try {
        Undo-Transaction
    }
    catch {
        Write-Warn "Автоматический rollback завершился ошибкой: $($_.Exception.Message)"
        if ($script:BackupPath) {
            Write-Warn "Ручной backup: $script:BackupPath"
        }
    }
    Write-Host
    Write-Host "  ✗ $($_.Exception.Message)" -ForegroundColor Red
    Write-Host
    throw
}
finally {
    if (
        $script:NextRuntimePath -and
        (Test-Path -LiteralPath $script:NextRuntimePath)
    ) {
        Remove-SafeRuntimeTree -Path $script:NextRuntimePath
    }
    Remove-SafeTemporaryRoot -Path $temporaryRoot
}
