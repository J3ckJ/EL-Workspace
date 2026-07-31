#requires -Version 7.2

[CmdletBinding()]
param(
    [string] $Version,
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepositoryRoot = [IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..')
)
if (-not $Version) {
    $versionPath = Join-Path $script:RepositoryRoot 'VERSION'
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
        throw 'VERSION не найден и -Version не указан.'
    }
    $Version = (Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8).Trim()
}
if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$') {
    throw "Некорректная release version: $Version"
}
if (-not $OutputPath) {
    $OutputPath = Join-Path $script:RepositoryRoot 'dist'
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)

$script:ArchiveRootName = "EL-Workspace-$Version"
$script:ArchiveName = "$($script:ArchiveRootName).zip"
$script:ArchivePath = Join-Path $OutputPath $script:ArchiveName
$script:InstallerPath = Join-Path $script:RepositoryRoot 'install.ps1'
$script:ReleaseInstallerPath = Join-Path $OutputPath 'install.ps1'
$script:ChecksumsPath = Join-Path $OutputPath 'SHA256SUMS.txt'
$script:FixedTimestamp = [DateTimeOffset]::new(
    2026,
    1,
    1,
    0,
    0,
    0,
    [TimeSpan]::Zero
)

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

function Assert-PlainTree {
    param([Parameter(Mandatory)][string] $Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "Release source directory не найден: $Root"
    }
    $rootItem = Get-Item -LiteralPath $Root -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Release source directory является reparse point: $Root"
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Force -Recurse)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Release source содержит reparse point: $($item.FullName)"
        }
        if (-not $item.PSIsContainer -and $item.Length -gt 16MB) {
            throw "Release source содержит файл больше 16 MB: $($item.FullName)"
        }
    }
}

function Get-ReleaseFiles {
    $trees = [ordered]@{
        'src' = Join-Path $script:RepositoryRoot 'src'
        'defaults' = Join-Path $script:RepositoryRoot 'defaults'
        'themes' = Join-Path $script:RepositoryRoot 'themes'
    }
    $files = [Collections.Generic.List[object]]::new()
    foreach ($entry in $trees.GetEnumerator()) {
        Assert-PlainTree -Root $entry.Value
        foreach ($file in @(Get-ChildItem `
            -LiteralPath $entry.Value `
            -Force `
            -Recurse `
            -File | Sort-Object FullName
        )) {
            $relative = [IO.Path]::GetRelativePath($entry.Value, $file.FullName)
            $destination = ($entry.Key + '/' + $relative.Replace('\', '/'))
            $files.Add([pscustomobject]@{
                Source = $file.FullName
                Destination = $destination
            })
        }
    }

    foreach ($fileName in @(
        'VERSION',
        'README.md',
        'CHANGELOG.md',
        'SECURITY.md',
        'LICENSE'
    )) {
        $path = Join-Path $script:RepositoryRoot $fileName
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $item = Get-Item -LiteralPath $path -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Release root file является reparse point: $path"
            }
            $files.Add([pscustomobject]@{
                Source = $path
                Destination = $fileName
            })
        }
    }
    return @($files)
}

function Assert-ReleaseInputs {
    $requiredFiles = @(
        'src\Terminal\el.ps1',
        'src\Terminal\el-project.ps1',
        'src\Terminal\workspace-pane.ps1',
        'src\Terminal\el-workspace.ps1',
        'src\Terminal\profile.ps1',
        'src\Terminal\projects.schema.json',
        'src\Terminal\el-project.schema.json',
        'defaults\projects.json',
        'defaults\launcher-state.json',
        'themes\el-midnight.omp.json',
        'themes\el-midnight.terminal.json',
        'install.ps1'
    )
    foreach ($relativePath in $requiredFiles) {
        $path = Join-Path $script:RepositoryRoot $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Отсутствует release input: $relativePath"
        }
    }

    foreach ($forbiddenPath in @(
        'src\Terminal\projects.json',
        'src\Terminal\launcher-state.json',
        'src\Terminal\install.json',
        'src\Terminal\.projects.lock',
        'src\Terminal\.launcher-state.lock',
        'src\Terminal\backups'
    )) {
        if (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $forbiddenPath)) {
            throw "User-specific data не должна входить в release: $forbiddenPath"
        }
    }

    foreach ($powerShellFile in @(Get-ChildItem `
        -LiteralPath (Join-Path $script:RepositoryRoot 'src\Terminal') `
        -Recurse `
        -File `
        -Filter '*.ps1'
    ) + @((Get-Item -LiteralPath $script:InstallerPath))) {
        Test-PowerShellFile -FilePath $powerShellFile.FullName
    }
    foreach ($jsonFile in @(Get-ChildItem `
        -Path @(
            (Join-Path $script:RepositoryRoot 'src\Terminal'),
            (Join-Path $script:RepositoryRoot 'defaults'),
            (Join-Path $script:RepositoryRoot 'themes')
        ) `
        -Recurse `
        -File `
        -Filter '*.json'
    )) {
        try {
            [void] (Get-Content `
                -LiteralPath $jsonFile.FullName `
                -Raw `
                -Encoding UTF8 | ConvertFrom-Json -Depth 100)
        }
        catch {
            throw "Некорректный JSON $($jsonFile.FullName) — $($_.Exception.Message)"
        }
    }

    foreach ($versionedFile in @(
        $script:InstallerPath,
        (Join-Path $script:RepositoryRoot 'src\Terminal\el-workspace.ps1')
    )) {
        $versionedText = Get-Content `
            -LiteralPath $versionedFile `
            -Raw `
            -Encoding UTF8
        $versionMatch = [regex]::Match(
            $versionedText,
            '(?m)^\$script:Version\s*=\s*''([^'']+)''\s*$'
        )
        if (
            -not $versionMatch.Success -or
            $versionMatch.Groups[1].Value -ne $Version
        ) {
            $relativeVersionedFile = [IO.Path]::GetRelativePath(
                $script:RepositoryRoot,
                $versionedFile
            )
            throw "Version drift между VERSION и $relativeVersionedFile."
        }
    }
}

function Write-AtomicText {
    param(
        [Parameter(Mandatory)][string] $Destination,
        [Parameter(Mandatory)][string] $Content
    )

    $temporary = $Destination + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText(
            $temporary,
            $Content,
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

Assert-ReleaseInputs
$releaseFiles = @(Get-ReleaseFiles)
if ($releaseFiles.Count -eq 0) {
    throw 'Release file list пуст.'
}
[void] [IO.Directory]::CreateDirectory($OutputPath)

$temporaryArchive = $script:ArchivePath + '.' +
    [Guid]::NewGuid().ToString('N') + '.tmp'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$stream = [IO.File]::Open(
    $temporaryArchive,
    [IO.FileMode]::CreateNew,
    [IO.FileAccess]::ReadWrite,
    [IO.FileShare]::None
)
try {
    $archive = [IO.Compression.ZipArchive]::new(
        $stream,
        [IO.Compression.ZipArchiveMode]::Create,
        $false
    )
    try {
        foreach ($file in $releaseFiles) {
            $entryName = "$($script:ArchiveRootName)/$($file.Destination)"
            $entry = $archive.CreateEntry(
                $entryName,
                [IO.Compression.CompressionLevel]::Optimal
            )
            $entry.LastWriteTime = $script:FixedTimestamp
            $entry.ExternalAttributes = (0x81A4 -shl 16)
            $input = [IO.File]::OpenRead($file.Source)
            $output = $entry.Open()
            try {
                $input.CopyTo($output)
            }
            finally {
                $output.Dispose()
                $input.Dispose()
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}
finally {
    $stream.Dispose()
}
Move-Item `
    -LiteralPath $temporaryArchive `
    -Destination $script:ArchivePath `
    -Force
Copy-Item `
    -LiteralPath $script:InstallerPath `
    -Destination $script:ReleaseInstallerPath `
    -Force

$archiveHash = (Get-FileHash `
    -LiteralPath $script:ArchivePath `
    -Algorithm SHA256
).Hash.ToLowerInvariant()
$installerHash = (Get-FileHash `
    -LiteralPath $script:ReleaseInstallerPath `
    -Algorithm SHA256
).Hash.ToLowerInvariant()
Write-AtomicText `
    -Destination $script:ChecksumsPath `
    -Content (
        "$archiveHash  $($script:ArchiveName)`n" +
        "$installerHash  install.ps1`n"
    )

Write-Host $script:ArchivePath
Write-Host "SHA-256 $archiveHash"
Write-Host $script:ReleaseInstallerPath
Write-Host "SHA-256 $installerHash"
Write-Host $script:ChecksumsPath
