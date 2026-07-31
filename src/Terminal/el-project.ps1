[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Command = 'help',

    [Parameter(Position = 1)]
    [string] $Target,

    [Parameter(Position = 2)]
    [string] $Task,

    [string] $Name,

    [ValidateSet('pwa', 'compose', 'node', 'python', 'dotnet', 'rust', 'go', 'generic')]
    [string] $Stack,

    [string] $Icon,

    [ValidatePattern('^[a-fA-F0-9]{64}$')]
    [string] $TrustManifestHash,

    [switch] $Yes,

    [switch] $Json,

    [switch] $Console,

    [switch] $Check,

    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ToolRoot = $PSScriptRoot
$script:RegistryPath = Join-Path $script:ToolRoot 'projects.json'
$script:SchemaPath = Join-Path $script:ToolRoot 'projects.schema.json'
$script:ManifestSchemaPath = Join-Path $script:ToolRoot 'el-project.schema.json'
$script:RunnerPath = Join-Path $script:ToolRoot 'workspace-pane.ps1'
$script:BackupRoot = Join-Path $script:ToolRoot 'backups'
$script:TransactionPath = Join-Path $script:ToolRoot '.projects.transaction.json'
$script:RegistryMutexName = 'Local\EL.ProjectManager.Registry.v2'
$script:RegistryLockPath = Join-Path $script:ToolRoot '.projects.lock'
$script:FragmentPath = if (
    $env:EL_WORKSPACE_TEST_MODE -eq '1' -and
    $env:EL_WORKSPACE_TEST_FRAGMENT
) {
    [IO.Path]::GetFullPath($env:EL_WORKSPACE_TEST_FRAGMENT)
}
else {
    Join-Path (
        [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    ) 'Microsoft\Windows Terminal\Fragments\EL.ProjectManager\projects.json'
}
$script:FragmentRoot = Split-Path -Parent $script:FragmentPath
$script:AllowedAccents = @(
    'Black', 'DarkBlue', 'DarkGreen', 'DarkCyan', 'DarkRed', 'DarkMagenta',
    'DarkYellow', 'Gray', 'DarkGray', 'Blue', 'Green', 'Cyan', 'Red',
    'Magenta', 'Yellow', 'White'
)
$script:AllowedRunners = @(
    'gitStatus', 'pythonModule', 'packageScript', 'packageBinary',
    'powershellFile', 'installedTool', 'dotnet', 'cargo', 'go',
    'workspaceShell', 'openRepository', 'message'
)

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

function Test-SafeText {
    param(
        [AllowNull()]
        [string] $Value,
        [int] $MaximumLength = 512
    )

    if ($null -eq $Value -or $Value.Length -gt $MaximumLength) {
        return $false
    }

    return $Value -notmatch '[\x00-\x08\x0A-\x1F\x7F]'
}

function Resolve-ProjectRoot {
    param([Parameter(Mandatory)][string] $Path)

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    if ($resolved.Provider.Name -ne 'FileSystem') {
        throw "Поддерживаются только файловые каталоги: $Path"
    }

    $item = Get-Item -LiteralPath $resolved.ProviderPath -Force
    if (-not $item.PSIsContainer) {
        throw "Это не каталог проекта: $Path"
    }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Корень проекта не может быть symlink, junction или другим reparse point.'
    }

    $fullPath = [IO.Path]::GetFullPath($item.FullName).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $root = [IO.Path]::GetPathRoot($fullPath).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )

    if ($fullPath.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Нельзя зарегистрировать корень диска как проект.'
    }

    $forbiddenExact = @(
        [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
    ) | Where-Object { $_ }

    foreach ($forbidden in $forbiddenExact) {
        $normalizedForbidden = [IO.Path]::GetFullPath($forbidden).TrimEnd('\', '/')
        if ($fullPath.Equals($normalizedForbidden, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Слишком широкий системный каталог нельзя зарегистрировать: $fullPath"
        }
    }

    return $fullPath
}

function ConvertTo-ProjectId {
    param([Parameter(Mandatory)][string] $DisplayName)

    $normalized = $DisplayName.Normalize([Text.NormalizationForm]::FormD)
    $builder = [Text.StringBuilder]::new()
    foreach ($character in $normalized.ToCharArray()) {
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($character)
        if ($category -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void] $builder.Append($character)
        }
    }

    $id = $builder.ToString().ToLowerInvariant()
    $id = [Regex]::Replace($id, '[^a-z0-9]+', '-').Trim('-')
    if (-not $id) {
        $id = 'project-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    }
    if ($id.Length -gt 48) {
        $id = $id.Substring(0, 48).TrimEnd('-')
    }
    return $id
}

function Read-Registry {
    if (-not (Test-Path -LiteralPath $script:RegistryPath -PathType Leaf)) {
        throw "Реестр проектов не найден: $script:RegistryPath"
    }

    try {
        $registryJson = Get-Content `
            -LiteralPath $script:RegistryPath `
            -Raw `
            -Encoding UTF8
        $document = [Text.Json.JsonDocument]::Parse([string] $registryJson)
        try {
            Assert-NoDuplicateJsonProperties -Element $document.RootElement
        }
        finally {
            $document.Dispose()
        }
        $schemaJson = Get-Content `
            -LiteralPath $script:SchemaPath `
            -Raw `
            -Encoding UTF8
        if (-not ($registryJson |
            Test-Json -Schema $schemaJson -ErrorAction SilentlyContinue)) {
            throw 'Реестр проектов не соответствует projects.schema.json.'
        }
        $registry = $registryJson | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "Реестр проектов повреждён: $($_.Exception.Message)"
    }

    Assert-Registry -Registry $registry
    return $registry
}

function Assert-Arguments {
    param([AllowNull()] $Arguments)

    foreach ($argument in @($Arguments)) {
        if ($argument -isnot [string] -or -not (Test-SafeText -Value $argument)) {
            throw 'Аргумент задачи содержит недопустимые управляющие символы или слишком длинный текст.'
        }
    }
}

function Assert-RelativePathInsideRoot {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $RelativePath,
        [switch] $MustExist,
        [switch] $Leaf
    )

    if ([IO.Path]::IsPathRooted($RelativePath) -or -not (Test-SafeText -Value $RelativePath)) {
        throw "Ожидался безопасный относительный путь: $RelativePath"
    }

    $candidate = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    $relative = [IO.Path]::GetRelativePath($Root, $candidate)
    if ($relative -eq '..' -or $relative.StartsWith(
        '..' + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::Ordinal
    )) {
        throw "Путь задачи выходит за пределы проекта: $RelativePath"
    }

    if ($MustExist) {
        $pathType = if ($Leaf) { 'Leaf' } else { 'Container' }
        if (-not (Test-Path -LiteralPath $candidate -PathType $pathType)) {
            throw "Путь задачи не найден: $candidate"
        }
    }

    return $candidate
}

function Assert-Step {
    param(
        [Parameter(Mandatory)] $Project,
        [Parameter(Mandatory)] $Step
    )

    if ($Step.runner -notin $script:AllowedRunners) {
        throw "Неизвестный безопасный runner '$($Step.runner)' в проекте '$($Project.id)'."
    }

    $commonExecutionFields = @('runner', 'arguments', 'cwd', 'continueOnError')
    $allowedFields = switch ($Step.runner) {
        'gitStatus' { @('runner', 'cwd', 'continueOnError') }
        'workspaceShell' { @('runner', 'cwd', 'continueOnError') }
        'pythonModule' { $commonExecutionFields + @('module') }
        'packageScript' { $commonExecutionFields + @('manager', 'script') }
        'packageBinary' { $commonExecutionFields + @('name') }
        'powershellFile' { $commonExecutionFields + @('path') }
        'installedTool' { $commonExecutionFields + @('name', 'preferred') }
        'dotnet' { $commonExecutionFields + @('verb') }
        'cargo' { $commonExecutionFields + @('verb') }
        'go' { $commonExecutionFields + @('verb') }
        'openRepository' { @('runner', 'continueOnError') }
        'message' { @('runner', 'text', 'continueOnError') }
    }
    foreach ($property in $Step.PSObject.Properties) {
        if ($property.Name -notin $allowedFields) {
            throw (
                "Поле '$($property.Name)' недопустимо для runner " +
                "'$($Step.runner)' в проекте '$($Project.id)'."
            )
        }
    }

    $requiredFields = switch ($Step.runner) {
        'workspaceShell' { @('cwd') }
        'pythonModule' { @('module') }
        'packageScript' { @('manager', 'script') }
        'packageBinary' { @('name') }
        'powershellFile' { @('path') }
        'installedTool' { @('name') }
        'dotnet' { @('verb') }
        'cargo' { @('verb') }
        'go' { @('verb') }
        'message' { @('text') }
        default { @() }
    }
    foreach ($requiredField in $requiredFields) {
        if ($Step.PSObject.Properties.Name -notcontains $requiredField) {
            throw (
                "Для runner '$($Step.runner)' отсутствует поле " +
                "'$requiredField'."
            )
        }
    }

    if ($Step.PSObject.Properties.Name -contains 'arguments') {
        Assert-Arguments -Arguments $Step.arguments
    }

    if ($Step.PSObject.Properties.Name -contains 'cwd') {
        [void] (Assert-RelativePathInsideRoot -Root $Project.root -RelativePath $Step.cwd)
    }

    switch ($Step.runner) {
        'pythonModule' {
            if ($Step.module -notin @('unittest', 'pytest', 'uvicorn')) {
                throw "Недопустимый Python-модуль задачи: $($Step.module)"
            }
        }
        'packageScript' {
            if ($Step.manager -notin @('npm', 'pnpm', 'yarn', 'bun')) {
                throw "Неподдерживаемый package manager: $($Step.manager)"
            }
            if ($Step.script -notmatch '^[A-Za-z0-9][A-Za-z0-9:._-]{0,63}$') {
                throw "Недопустимое имя package script: $($Step.script)"
            }
            $dangerous = 'clean', 'purge', 'deploy', 'publish', 'release',
                'migrate', 'uninstall'
            if ($Step.script -in $dangerous -or $Step.script.StartsWith('db:')) {
                throw "Опасная package-задача не может быть добавлена автоматически: $($Step.script)"
            }
        }
        'packageBinary' {
            if ($Step.name -notin @('tsc')) {
                throw "Неподдерживаемый локальный package binary: $($Step.name)"
            }
        }
        'powershellFile' {
            if (-not $Step.path.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'powershellFile должен указывать на .ps1.'
            }
            [void] (Assert-RelativePathInsideRoot -Root $Project.root -RelativePath $Step.path)
        }
        'installedTool' {
            if ($Step.name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
                throw "Недопустимое имя установленного инструмента: $($Step.name)"
            }
            if ($Step.PSObject.Properties.Name -contains 'preferred') {
                if ($Step.preferred.base -ne 'LocalAppData') {
                    throw 'Поддерживается только preferred.base = LocalAppData.'
                }
                if ([IO.Path]::IsPathRooted($Step.preferred.path) -or
                    -not (Test-SafeText -Value $Step.preferred.path)) {
                    throw 'preferred.path должен быть безопасным относительным путём.'
                }
            }
        }
        'dotnet' {
            if ($Step.verb -notin @('build', 'test', 'run')) {
                throw "Недопустимый dotnet verb: $($Step.verb)"
            }
        }
        'cargo' {
            if ($Step.verb -notin @('build', 'check', 'test', 'run')) {
                throw "Недопустимый cargo verb: $($Step.verb)"
            }
        }
        'go' {
            if ($Step.verb -notin @('test', 'vet', 'run')) {
                throw "Недопустимый go verb: $($Step.verb)"
            }
        }
        'message' {
            if (-not (Test-SafeText -Value $Step.text -MaximumLength 1024)) {
                throw 'Текст сообщения задачи недопустим.'
            }
        }
    }
}

function Assert-Registry {
    param([Parameter(Mandatory)] $Registry)

    if (-not (Test-Path -LiteralPath $script:SchemaPath -PathType Leaf)) {
        throw "JSON Schema реестра не найдена: $script:SchemaPath"
    }
    $schemaJson = Get-Content -LiteralPath $script:SchemaPath -Raw -Encoding UTF8
    $registryJson = $Registry | ConvertTo-Json -Depth 100
    if (-not ($registryJson | Test-Json -Schema $schemaJson -ErrorAction SilentlyContinue)) {
        throw 'Реестр проектов не соответствует projects.schema.json.'
    }

    if ($Registry.schemaVersion -ne 1) {
        throw "Неподдерживаемая версия реестра: $($Registry.schemaVersion)"
    }
    if ($Registry.PSObject.Properties.Name -contains 'updatedAt') {
        $parsedUpdatedAt = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse(
            [string] $Registry.updatedAt,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref] $parsedUpdatedAt
        )) {
            throw "updatedAt содержит недопустимую дату: $($Registry.updatedAt)"
        }
    }
    if (-not $Registry.defaults.terminalProfile) {
        throw 'В реестре не задан defaults.terminalProfile.'
    }

    $projectIds = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $projectRoots = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )

    foreach ($project in @($Registry.projects)) {
        if ($project.id -notmatch '^[a-z0-9][a-z0-9-]{0,47}$') {
            throw "Недопустимый ID проекта: $($project.id)"
        }
        if (-not $projectIds.Add($project.id)) {
            throw "ID проекта повторяется: $($project.id)"
        }
        if (-not (Test-SafeText -Value $project.displayName -MaximumLength 80) -or
            [string]::IsNullOrWhiteSpace($project.displayName)) {
            throw "Недопустимое имя проекта: $($project.id)"
        }
        if (-not [IO.Path]::IsPathFullyQualified($project.root)) {
            throw "Корень проекта должен быть абсолютным: $($project.root)"
        }
        $normalizedRoot = [IO.Path]::GetFullPath($project.root).TrimEnd('\', '/')
        if (-not $projectRoots.Add($normalizedRoot)) {
            throw "Один каталог зарегистрирован дважды: $normalizedRoot"
        }
        if ($project.presentation.accent -notin $script:AllowedAccents) {
            throw "Недопустимый цвет проекта '$($project.id)': $($project.presentation.accent)"
        }
        if (-not (Test-SafeText -Value $project.presentation.icon -MaximumLength 8)) {
            throw "Недопустимая иконка проекта: $($project.id)"
        }
        if ($project.repository) {
            $repositoryUri = $null
            if (-not [Uri]::TryCreate(
                $project.repository,
                [UriKind]::Absolute,
                [ref] $repositoryUri
            ) -or
                $repositoryUri.Scheme -ne 'https' -or
                $repositoryUri.UserInfo -or
                $repositoryUri.Query -or
                $repositoryUri.Fragment) {
                throw "URL репозитория должен использовать HTTPS: $($project.repository)"
            }
        }

        $taskIds = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        foreach ($task in @($project.tasks)) {
            if ($task.id -notmatch '^[a-z0-9][a-z0-9-]{0,47}$') {
                throw "Недопустимый ID задачи '$($task.id)' в проекте '$($project.id)'."
            }
            if (-not $taskIds.Add($task.id)) {
                throw "Задача повторяется: $($project.id)/$($task.id)"
            }
            if (-not (Test-SafeText -Value $task.label -MaximumLength 100) -or
                -not (Test-SafeText -Value $task.tabTitle -MaximumLength 100) -or
                -not (Test-SafeText -Value $task.icon -MaximumLength 8)) {
                throw "Недопустимое название задачи: $($project.id)/$($task.id)"
            }
            if ($task.PSObject.Properties.Name -contains 'environment') {
                foreach ($property in $task.environment.PSObject.Properties) {
                    if ($property.Name -notmatch '^[A-Z][A-Z0-9_]{0,63}$' -or
                        -not (Test-SafeText -Value ([string] $property.Value))) {
                        throw "Недопустимая переменная окружения: $($property.Name)"
                    }
                }
            }
            foreach ($step in @($task.steps)) {
                Assert-Step -Project $project -Step $step
            }
        }
        if (-not $taskIds.Contains('main')) {
            throw "В проекте '$($project.id)' отсутствует обязательная задача main."
        }

        foreach ($taskId in @($project.palette)) {
            if (-not $taskIds.Contains([string] $taskId)) {
                throw "Палитра ссылается на неизвестную задачу: $($project.id)/$taskId"
            }
        }

        $paneNumber = 0
        foreach ($pane in @($project.workspace)) {
            $paneNumber++
            if (-not $taskIds.Contains([string] $pane.task)) {
                throw "Workspace ссылается на неизвестную задачу: $($project.id)/$($pane.task)"
            }
            if ($paneNumber -eq 1 -and $pane.action -ne 'newTab') {
                throw "Первое окно workspace должно использовать newTab: $($project.id)"
            }
            if ($paneNumber -gt 1) {
                if ($pane.action -ne 'splitPane' -or $pane.split -notin @('right', 'down')) {
                    throw "Недопустимое разбиение workspace: $($project.id)"
                }
                $size = [double] $pane.size
                if ($size -lt 0.1 -or $size -gt 0.9) {
                    throw "Размер панели должен быть от 0.1 до 0.9: $($project.id)"
                }
            }
        }
    }
}

function Get-Project {
    param(
        [Parameter(Mandatory)] $Registry,
        [Parameter(Mandatory)][string] $Identity
    )

    $byId = @($Registry.projects | Where-Object {
        $_.id.Equals($Identity, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($byId.Count -eq 1) {
        return $byId[0]
    }

    $byName = @($Registry.projects | Where-Object {
        $_.displayName.Equals($Identity, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($byName.Count -eq 1) {
        return $byName[0]
    }

    if (Test-Path -LiteralPath $Identity -PathType Container) {
        $resolvedIdentity = [IO.Path]::GetFullPath(
            (Resolve-Path -LiteralPath $Identity).ProviderPath
        ).TrimEnd('\', '/')
        $byPath = @($Registry.projects | Where-Object {
            [IO.Path]::GetFullPath($_.root).TrimEnd('\', '/').Equals(
                $resolvedIdentity,
                [StringComparison]::OrdinalIgnoreCase
            )
        })
        if ($byPath.Count -eq 1) {
            return $byPath[0]
        }
    }

    throw "Проект '$Identity' не найден. Выполните: el-project list"
}

function Get-Task {
    param(
        [Parameter(Mandatory)] $Project,
        [Parameter(Mandatory)][string] $TaskId
    )

    $task = @($Project.tasks | Where-Object {
        $_.id.Equals($TaskId, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($task.Count -ne 1) {
        throw "Задача '$TaskId' не найдена в проекте '$($Project.id)'."
    }
    return $task[0]
}

function ConvertTo-StableJson {
    param([Parameter(Mandatory)] $Value)
    return ($Value | ConvertTo-Json -Depth 100) + [Environment]::NewLine
}

function Write-AtomicUtf8 {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Content,
        [Parameter(Mandatory)][string] $BackupPrefix
    )

    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    [IO.Directory]::CreateDirectory($script:BackupRoot) | Out-Null

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $current = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        if ($current -eq $Content) {
            return $false
        }
    }

    $temporary = Join-Path $directory (
        '.{0}.{1}.{2}.tmp' -f [IO.Path]::GetFileName($Path), $PID,
        [Guid]::NewGuid().ToString('N')
    )
    $utf8 = [Text.UTF8Encoding]::new($false)
    try {
        $stream = [IO.FileStream]::new(
            $temporary,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough
        )
        try {
            $bytes = $utf8.GetBytes($Content)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }

        [void] ([IO.File]::ReadAllText($temporary, $utf8) | ConvertFrom-Json -Depth 100)

        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
            $nonce = [Guid]::NewGuid().ToString('N').Substring(0, 8)
            $backup = Join-Path $script:BackupRoot (
                "$BackupPrefix-$timestamp-$nonce.json"
            )
            [IO.File]::Replace($temporary, $Path, $backup, $true)
        }
        else {
            [IO.File]::Move($temporary, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }

    [void] ([IO.File]::ReadAllText($Path, $utf8) | ConvertFrom-Json -Depth 100)
    return $true
}

function Get-ContentSha256 {
    param([Parameter(Mandatory)][string] $Content)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Content)
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($bytes)
    ).ToLowerInvariant()
}

function Get-FileContentOrNull {
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}

function Restore-TransactionFile {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][bool] $Existed,
        [AllowNull()][string] $Base64,
        [Parameter(Mandatory)][string] $BackupPrefix
    )

    if ($Existed) {
        $content = [Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String($Base64)
        )
        [void] (Write-AtomicUtf8 `
            -Path $Path `
            -Content $content `
            -BackupPrefix $BackupPrefix)
    }
    elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Recover-PendingTransaction {
    if (-not (Test-Path -LiteralPath $script:TransactionPath -PathType Leaf)) {
        return
    }

    try {
        $journal = Get-Content `
            -LiteralPath $script:TransactionPath `
            -Raw `
            -Encoding UTF8 | ConvertFrom-Json -Depth 30
        if ($journal.schemaVersion -ne 1) {
            throw 'Неподдерживаемая версия transaction journal.'
        }

        $registryContent = Get-FileContentOrNull -Path $script:RegistryPath
        $fragmentContent = Get-FileContentOrNull -Path $script:FragmentPath
        $alreadyCommitted =
            $null -ne $registryContent -and
            $null -ne $fragmentContent -and
            (Get-ContentSha256 -Content $registryContent) -eq
                $journal.newRegistrySha256 -and
            (Get-ContentSha256 -Content $fragmentContent) -eq
                $journal.newFragmentSha256
        if (-not $alreadyCommitted) {
            Restore-TransactionFile `
                -Path $script:FragmentPath `
                -Existed ([bool] $journal.oldFragmentExisted) `
                -Base64 $journal.oldFragmentBase64 `
                -BackupPrefix 'transaction-fragment-recovery'
            Restore-TransactionFile `
                -Path $script:RegistryPath `
                -Existed ([bool] $journal.oldRegistryExisted) `
                -Base64 $journal.oldRegistryBase64 `
                -BackupPrefix 'transaction-registry-recovery'
            Write-Warning 'Незавершённое обновление реестра восстановлено.'
        }
        Remove-Item -LiteralPath $script:TransactionPath -Force
    }
    catch {
        throw "Не удалось восстановить transaction journal: $($_.Exception.Message)"
    }
}

function New-RunnerCommandLine {
    param(
        [Parameter(Mandatory)][string] $ProjectId,
        [Parameter(Mandatory)][string] $TaskId
    )

    $quotedRunner = '"' + $script:RunnerPath.Replace('"', '\"') + '"'
    return "pwsh.exe -NoLogo -NoExit -File $quotedRunner -ProjectId $ProjectId -TaskId $TaskId"
}

function Get-TaskTabColor {
    param(
        [Parameter(Mandatory)] $Project,
        [Parameter(Mandatory)] $Task
    )

    $colors = @{
        Black = '#0A1028'
        DarkBlue = '#34466D'
        DarkGreen = '#315C46'
        DarkCyan = '#2D7180'
        DarkRed = '#8F4A50'
        DarkMagenta = '#715E93'
        DarkYellow = '#8C682E'
        Gray = '#9DAAC5'
        DarkGray = '#66758F'
        Blue = '#73A5FF'
        Green = '#81D4A0'
        Cyan = '#67D4E8'
        Red = '#FF6B6B'
        Magenta = '#B69CFF'
        Yellow = '#E6A13A'
        White = '#E8F1FF'
    }
    $taskId = ([string] $Task.id).ToLowerInvariant()
    $roleColor = switch -Regex ($taskId) {
        '(^|-)frontend($|-)' { 'Cyan'; break }
        '(^|-)backend($|-)|(^|-)api($|-)' { 'Magenta'; break }
        'test' { 'Green'; break }
        'check|lint|doctor' { 'Yellow'; break }
        'build' { 'DarkMagenta'; break }
        'repository' { 'DarkGray'; break }
        default { [string] $Project.presentation.accent }
    }
    if ($colors.ContainsKey($roleColor)) {
        return $colors[$roleColor]
    }
    return '#73A5FF'
}

function Get-TerminalTaskTitle {
    param(
        [Parameter(Mandatory)] $Project,
        [Parameter(Mandatory)] $Task
    )

    return "$($Task.icon) EL · $($Project.displayName) · $($Task.label)"
}

function New-TerminalTaskAction {
    param(
        [Parameter(Mandatory)] $Registry,
        [Parameter(Mandatory)] $Project,
        [Parameter(Mandatory)] $Task,
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $Name
    )

    return [ordered]@{
        command = [ordered]@{
            action = 'newTab'
            commandline = New-RunnerCommandLine -ProjectId $Project.id -TaskId $Task.id
            profile = $Registry.defaults.terminalProfile
            startingDirectory = $Project.root
            suppressApplicationTitle = $true
            tabColor = Get-TaskTabColor -Project $Project -Task $Task
            tabTitle = Get-TerminalTaskTitle -Project $Project -Task $Task
        }
        icon = $Task.icon
        id = $Id
        name = $Name
    }
}

function New-TerminalFragment {
    param([Parameter(Mandatory)] $Registry)

    $groups = [Collections.Generic.List[object]]::new()
    foreach ($project in @($Registry.projects)) {
        $commands = [Collections.Generic.List[object]]::new()

        if (@($project.workspace).Count -gt 0) {
            $paneActions = [Collections.Generic.List[object]]::new()
            foreach ($pane in @($project.workspace)) {
                $task = Get-Task -Project $project -TaskId $pane.task
                $paneAction = [ordered]@{
                    action = $pane.action
                    commandline = New-RunnerCommandLine -ProjectId $project.id -TaskId $task.id
                    profile = $Registry.defaults.terminalProfile
                    startingDirectory = $project.root
                    suppressApplicationTitle = $true
                    tabColor = Get-TaskTabColor -Project $project -Task $task
                    tabTitle = Get-TerminalTaskTitle -Project $project -Task $task
                }
                if ($pane.action -eq 'splitPane') {
                    $paneAction.size = [double] $pane.size
                    $paneAction.split = $pane.split
                }
                $paneActions.Add($paneAction)
            }
            $paneActions.Add([ordered]@{
                action = 'moveFocus'
                direction = 'first'
            })

            $commands.Add([ordered]@{
                command = [ordered]@{
                    action = 'multipleActions'
                    actions = @($paneActions)
                }
                icon = '▦'
                id = "User.EL.Project.$($project.id).Workspace"
                name = 'Рабочее пространство'
            })
        }

        $mainTask = @($project.tasks | Where-Object { $_.id -eq 'main' })
        if ($mainTask.Count -eq 1) {
            $commands.Add((New-TerminalTaskAction `
                -Registry $Registry `
                -Project $project `
                -Task $mainTask[0] `
                -Id "User.EL.Project.$($project.id).Open" `
                -Name 'Открыть консоль проекта'))
        }

        foreach ($taskId in @($project.palette)) {
            if ($taskId -eq 'main') {
                continue
            }
            $task = Get-Task -Project $project -TaskId $taskId
            $commands.Add((New-TerminalTaskAction `
                -Registry $Registry `
                -Project $project `
                -Task $task `
                -Id "User.EL.Project.$($project.id).Role.$($task.id)" `
                -Name $task.label))
        }

        $groups.Add([ordered]@{
            commands = @($commands)
            icon = $project.presentation.icon
            id = "User.EL.Project.$($project.id)"
            name = "EL · $($project.displayName)"
        })
    }

    return [ordered]@{
        '$schema' = 'https://aka.ms/terminal-profiles-schema'
        actions = @($groups)
    }
}

function Get-TerminalSettingsPaths {
    $localData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::LocalApplicationData
    )
    $candidates = @(
        (Join-Path $localData 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $localData 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $localData 'Microsoft\Windows Terminal\settings.json')
    )

    return @($candidates | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    })
}

function Update-TerminalReloadSignal {
    $settingsPaths = @(Get-TerminalSettingsPaths)
    if ($settingsPaths.Count -eq 0) {
        return
    }

    foreach ($settingsPath in $settingsPaths) {
        try {
            [void] (Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 |
                ConvertFrom-Json -Depth 100)
            [IO.File]::SetLastWriteTimeUtc($settingsPath, [DateTime]::UtcNow)
        }
        catch {
            Write-Warning "Палитра записана, но Terminal не удалось попросить перечитать '$settingsPath': $($_.Exception.Message)"
        }
    }
}

function Sync-Projects {
    param(
        [Parameter(Mandatory)] $Registry,
        [switch] $CheckOnly,
        [switch] $Preview
    )

    Assert-Registry -Registry $Registry
    $fragment = New-TerminalFragment -Registry $Registry
    $content = ConvertTo-StableJson -Value $fragment

    if ($Preview) {
        Write-Output $content
        return
    }

    if ($CheckOnly) {
        if (-not (Test-Path -LiteralPath $script:FragmentPath -PathType Leaf)) {
            Write-Failure 'Фрагмент палитры отсутствует.'
            return $false
        }
        $current = [IO.File]::ReadAllText($script:FragmentPath, [Text.Encoding]::UTF8)
        if ($current -ne $content) {
            Write-Failure 'Фрагмент палитры отстаёт от реестра.'
            return $false
        }
        Write-Success 'Реестр и палитра синхронизированы.'
        return $true
    }

    $changed = Write-AtomicUtf8 `
        -Path $script:FragmentPath `
        -Content $content `
        -BackupPrefix 'terminal-fragment'
    if ($changed) {
        Update-TerminalReloadSignal
        Write-Success 'Палитра Windows Terminal обновлена.'
    }
    else {
        Write-Success 'Палитра уже актуальна.'
    }
    return $true
}

function Test-GitRepository {
    param(
        [Parameter(Mandatory)][string] $Root,
        [switch] $Trusted
    )

    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $git) {
        return $false
    }
    $gitArguments = [Collections.Generic.List[string]]::new()
    if ($Trusted) {
        $gitArguments.Add('-c')
        $gitArguments.Add("safe.directory=$Root")
    }
    $gitArguments.Add('-C')
    $gitArguments.Add($Root)
    $gitArguments.Add('rev-parse')
    $gitArguments.Add('--is-inside-work-tree')
    $global:LASTEXITCODE = 0
    $result = & $git.Source @gitArguments 2>$null
    return $LASTEXITCODE -eq 0 -and "$result".Trim() -eq 'true'
}

function ConvertTo-SafeRepositoryUrl {
    param([Parameter(Mandatory)][string] $Value)

    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref] $uri) -or
        $uri.Scheme -ne 'https' -or
        $uri.UserInfo) {
        return $null
    }

    $builder = [UriBuilder]::new($uri)
    $builder.Query = ''
    $builder.Fragment = ''
    return $builder.Uri.AbsoluteUri.TrimEnd('/')
}

function Get-RepositoryUrl {
    param(
        [Parameter(Mandatory)][string] $Root,
        [switch] $Trusted
    )

    if (-not (Test-GitRepository -Root $Root -Trusted:$Trusted)) {
        return $null
    }

    $gitPrefix = if ($Trusted) {
        @('-c', "safe.directory=$Root", '-C', $Root)
    }
    else {
        @('-C', $Root)
    }
    $remoteNames = @(& git.exe @gitPrefix remote 2>$null)
    if ($LASTEXITCODE -ne 0 -or $remoteNames.Count -eq 0) {
        return $null
    }

    $remote = $null
    if ($remoteNames -contains 'origin') {
        $remote = 'origin'
    }
    else {
        $branch = (& git.exe @gitPrefix branch --show-current 2>$null |
            Select-Object -First 1)
        if ($branch) {
            $branchRemote = (& git.exe @gitPrefix config --get "branch.$branch.remote" 2>$null |
                Select-Object -First 1)
            if ($branchRemote -and $remoteNames -contains $branchRemote) {
                $remote = $branchRemote
            }
        }
    }
    if (-not $remote) {
        $remote = $remoteNames[0]
    }

    $url = (& git.exe @gitPrefix remote get-url $remote 2>$null |
        Select-Object -First 1)
    if (-not $url) {
        return $null
    }
    $url = "$url".Trim()

    if ($url -match '^git@github\.com:(?<path>.+?)(?:\.git)?$') {
        return (ConvertTo-SafeRepositoryUrl -Value (
            "https://github.com/$($Matches.path -replace '\.git$', '')"
        ))
    }
    if ($url -match '^ssh://git@github\.com/(?<path>.+?)(?:\.git)?$') {
        return (ConvertTo-SafeRepositoryUrl -Value (
            "https://github.com/$($Matches.path -replace '\.git$', '')"
        ))
    }
    if ($url -match '^https://') {
        return (ConvertTo-SafeRepositoryUrl -Value ($url -replace '\.git$', ''))
    }
    return $null
}

function Get-ComposeFilePath {
    param([Parameter(Mandatory)][string] $Root)

    foreach ($name in @(
        'compose.yaml',
        'compose.yml',
        'docker-compose.yaml',
        'docker-compose.yml'
    )) {
        $candidate = Join-Path $Root $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    return $null
}

function Test-PythonProjectMarker {
    param([Parameter(Mandatory)][string] $Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return $false
    }
    return (
        (Test-Path -LiteralPath (Join-Path $Root 'pyproject.toml') -PathType Leaf) -or
        (Test-Path -LiteralPath (Join-Path $Root 'setup.py') -PathType Leaf) -or
        [bool] (Get-ChildItem `
            -LiteralPath $Root `
            -Filter 'requirements*.txt' `
            -File `
            -ErrorAction SilentlyContinue)
    )
}

function Get-StackCandidates {
    param([Parameter(Mandatory)][string] $Root)

    $candidates = [Collections.Generic.List[string]]::new()

    # Product markers are stronger than the presence of a package manager.
    # A PWA may use Node.js only for tests or for a nested API, so package.json
    # alone must not replace the type of the whole product.
    $hasPwaShell =
        (Test-Path -LiteralPath (Join-Path $Root 'index.html') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Root 'manifest.webmanifest') -PathType Leaf)
    if ($hasPwaShell) {
        $candidates.Add('pwa')
        return @($candidates)
    }

    # Compose is a product-level marker. It owns the root while language
    # markers in backend/frontend describe its services, not competing roots.
    if (Get-ComposeFilePath -Root $Root) {
        $candidates.Add('compose')
        return @($candidates)
    }

    if (Test-Path -LiteralPath (Join-Path $Root 'package.json') -PathType Leaf) {
        $candidates.Add('node')
    }
    if (Test-PythonProjectMarker -Root $Root) {
        $candidates.Add('python')
    }
    if (
        (Get-ChildItem -LiteralPath $Root -Filter '*.sln' -File -ErrorAction SilentlyContinue) -or
        (Get-ChildItem -LiteralPath $Root -Filter '*.slnx' -File -ErrorAction SilentlyContinue) -or
        (Get-ChildItem -LiteralPath $Root -Filter '*.csproj' -File -ErrorAction SilentlyContinue)
    ) {
        $candidates.Add('dotnet')
    }
    if (Test-Path -LiteralPath (Join-Path $Root 'Cargo.toml') -PathType Leaf) {
        $candidates.Add('rust')
    }
    if (Test-Path -LiteralPath (Join-Path $Root 'go.mod') -PathType Leaf) {
        $candidates.Add('go')
    }
    if ($candidates.Count -eq 0) {
        $candidates.Add('generic')
    }
    return @($candidates)
}

function Select-DetectedStack {
    param(
        [Parameter(Mandatory)][string[]] $Candidates,
        [string] $Requested,
        [switch] $AssumeYes
    )

    if ($Requested) {
        return $Requested
    }
    if ($Candidates.Count -eq 1) {
        return $Candidates[0]
    }
    if ($AssumeYes -or [Console]::IsInputRedirected) {
        throw "Найдено несколько стеков ($($Candidates -join ', ')). Укажите -Stack."
    }

    Write-Host
    Write-Host '  Найдено несколько стеков:' -ForegroundColor Yellow
    for ($index = 0; $index -lt $Candidates.Count; $index++) {
        Write-Host "  $($index + 1). $($Candidates[$index])"
    }
    $choice = Read-Host '  Выберите номер'
    $number = 0
    if (-not [int]::TryParse($choice, [ref] $number) -or
        $number -lt 1 -or $number -gt $Candidates.Count) {
        throw 'Стек не выбран.'
    }
    return $Candidates[$number - 1]
}

function New-Step {
    param(
        [Parameter(Mandatory)][string] $Runner,
        [hashtable] $Properties
    )

    $step = [ordered]@{ runner = $Runner }
    foreach ($key in @($Properties.Keys)) {
        $step[$key] = $Properties[$key]
    }
    return [pscustomobject] $step
}

function New-Task {
    param(
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][string] $TabTitle,
        [Parameter(Mandatory)][string] $Icon,
        [Parameter(Mandatory)][object[]] $Steps,
        [hashtable] $Environment
    )

    $task = [ordered]@{
        id = $Id
        label = $Label
        tabTitle = $TabTitle
        icon = $Icon
        steps = @($Steps)
    }
    if ($Environment -and $Environment.Count -gt 0) {
        $task.environment = [pscustomobject] $Environment
    }
    return [pscustomobject] $task
}

function Add-RepositoryTask {
    param(
        [Parameter(Mandatory)][Collections.Generic.List[object]] $Tasks,
        [string] $Repository,
        [Parameter(Mandatory)][string] $DisplayName,
        [Parameter(Mandatory)][bool] $IsGit
    )

    if (-not $Repository) {
        return
    }
    $steps = [Collections.Generic.List[object]]::new()
    $steps.Add((New-Step -Runner 'openRepository' -Properties @{}))
    if ($IsGit) {
        $steps.Add((New-Step -Runner 'gitStatus' -Properties @{}))
    }
    $Tasks.Add((New-Task `
        -Id 'repository' `
        -Label 'Открыть репозиторий' `
        -TabTitle "$DisplayName · Repository" `
        -Icon '↗' `
        -Steps @($steps)))
}

function New-AutomaticWorkspace {
    param([Parameter(Mandatory)][string[]] $TaskIds)

    $panes = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt [Math]::Min(3, $TaskIds.Count); $index++) {
        if ($index -eq 0) {
            $panes.Add([pscustomobject][ordered]@{
                task = $TaskIds[$index]
                action = 'newTab'
            })
        }
        elseif ($index -eq 1) {
            $panes.Add([pscustomobject][ordered]@{
                task = $TaskIds[$index]
                action = 'splitPane'
                split = 'right'
                size = 0.42
            })
        }
        else {
            $panes.Add([pscustomobject][ordered]@{
                task = $TaskIds[$index]
                action = 'splitPane'
                split = 'down'
                size = 0.5
            })
        }
    }
    return @($panes)
}

function Read-PackageManifest {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Name
    )

    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 30
    }
    catch {
        throw "$Name повреждён: $($_.Exception.Message)"
    }
}

function Get-PackageManager {
    param([Parameter(Mandatory)][string] $Root)

    if (Test-Path -LiteralPath (Join-Path $Root 'pnpm-lock.yaml') -PathType Leaf) {
        return 'pnpm'
    }
    if (Test-Path -LiteralPath (Join-Path $Root 'yarn.lock') -PathType Leaf) {
        return 'yarn'
    }
    if (
        (Test-Path -LiteralPath (Join-Path $Root 'bun.lock') -PathType Leaf) -or
        (Test-Path -LiteralPath (Join-Path $Root 'bun.lockb') -PathType Leaf)
    ) {
        return 'bun'
    }
    return 'npm'
}

function Get-PackageScriptNames {
    param([Parameter(Mandatory)] $Package)

    if (
        $Package.PSObject.Properties.Name -contains 'scripts' -and
        $Package.scripts
    ) {
        return @($Package.scripts.PSObject.Properties.Name)
    }
    return @()
}

function Assert-NoDuplicateJsonProperties {
    param(
        [Parameter(Mandatory)]
        [Text.Json.JsonElement] $Element,
        [string] $Location = '$'
    )

    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) {
                throw "JSON содержит повторяющееся поле '$($property.Name)' в $Location."
            }
            Assert-NoDuplicateJsonProperties `
                -Element $property.Value `
                -Location "$Location.$($property.Name)"
        }
    }
    elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            Assert-NoDuplicateJsonProperties `
                -Element $item `
                -Location "$Location[$index]"
            $index++
        }
    }
}

function Read-ProjectManifest {
    param([Parameter(Mandatory)][string] $Root)

    $manifestPath = Join-Path $Root '.el-project.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        return $null
    }
    $item = Get-Item -LiteralPath $manifestPath -Force
    if ($item.PSIsContainer) {
        throw '.el-project.json должен быть обычным файлом.'
    }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw '.el-project.json не может быть symlink или другим reparse point.'
    }
    if ($item.Length -gt 65536) {
        throw '.el-project.json превышает безопасный лимит 64 KiB.'
    }
    if (-not (Test-Path -LiteralPath $script:ManifestSchemaPath -PathType Leaf)) {
        throw "Схема project manifest не найдена: $script:ManifestSchemaPath"
    }

    $bytes = [IO.File]::ReadAllBytes($manifestPath)
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    try {
        $json = $utf8.GetString($bytes)
        $document = [Text.Json.JsonDocument]::Parse([string] $json)
        try {
            Assert-NoDuplicateJsonProperties -Element $document.RootElement
        }
        finally {
            $document.Dispose()
        }
        $manifest = $json | ConvertFrom-Json -Depth 100
    }
    catch {
        throw ".el-project.json повреждён: $($_.Exception.Message)"
    }

    $schemaJson = Get-Content `
        -LiteralPath $script:ManifestSchemaPath `
        -Raw `
        -Encoding UTF8
    if (-not ($json | Test-Json -Schema $schemaJson -ErrorAction SilentlyContinue)) {
        throw '.el-project.json не соответствует el-project.schema.json.'
    }

    $hashBytes = [Security.Cryptography.SHA256]::HashData($bytes)
    return [pscustomobject][ordered]@{
        path = $manifestPath
        hash = [Convert]::ToHexString($hashBytes).ToLowerInvariant()
        data = $manifest
    }
}

function Test-ManifestPackageScript {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)] $Step
    )

    $workingRoot = if ($Step.PSObject.Properties.Name -contains 'cwd') {
        Assert-RelativePathInsideRoot `
            -Root $Root `
            -RelativePath $Step.cwd `
            -MustExist
    }
    else {
        $Root
    }
    $packagePath = Join-Path $workingRoot 'package.json'
    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        throw "Для packageScript не найден package.json: $workingRoot"
    }
    $package = Read-PackageManifest -Path $packagePath -Name (
        [IO.Path]::GetRelativePath($Root, $packagePath)
    )
    $scripts = @(Get-PackageScriptNames -Package $package)
    if ($scripts -notcontains $Step.script) {
        throw "Package script '$($Step.script)' не объявлен в $packagePath."
    }
}

function Assert-ManifestTaskPatch {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $TaskId,
        [Parameter(Mandatory)] $Patch
    )

    if ($Patch.PSObject.Properties.Name -contains 'environment') {
        $environmentProperties = @($Patch.environment.PSObject.Properties)
        if ($environmentProperties.Count -gt 32) {
            throw "Слишком много переменных окружения в задаче '$TaskId'."
        }
        foreach ($property in $environmentProperties) {
            if (
                $property.Name -match '(?i)(secret|token|password|passwd|api.?key)' -or
                [string] $property.Value -match '(%[^%]+%|\$\{|\$env:)'
            ) {
                throw (
                    "Задача '$TaskId' содержит секрет или подстановку окружения. " +
                    'Храните секреты вне .el-project.json.'
                )
            }
        }
    }

    if ($Patch.PSObject.Properties.Name -notcontains 'steps') {
        return
    }
    if (@($Patch.steps).Count -gt 8) {
        throw "В задаче '$TaskId' допускается не более 8 шагов."
    }
    foreach ($step in @($Patch.steps)) {
        if ($step.runner -eq 'installedTool') {
            throw (
                "Runner installedTool запрещён в .el-project.json: $TaskId. " +
                'Используйте один из проектных structured runners.'
            )
        }
        if (
            $step.PSObject.Properties.Name -contains 'arguments' -and
            @($step.arguments).Count -gt 32
        ) {
            throw "В одном шаге задачи '$TaskId' допускается не более 32 аргументов."
        }
        $probeProject = [pscustomobject]@{
            id = 'manifest-probe'
            root = $Root
        }
        Assert-Step -Project $probeProject -Step $step
        if ($step.runner -eq 'packageScript') {
            Test-ManifestPackageScript -Root $Root -Step $step
        }
    }
}

function Set-ObjectProperty {
    param(
        [Parameter(Mandatory)] $Object,
        [Parameter(Mandatory)][string] $Name,
        [AllowNull()] $Value
    )

    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.$Name = $Value
    }
    else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Assert-ProjectSnapshot {
    param(
        [Parameter(Mandatory)] $Project,
        [Parameter(Mandatory)][string] $TerminalProfile
    )

    $probe = [pscustomobject][ordered]@{
        '$schema' = './projects.schema.json'
        schemaVersion = 1
        defaults = [pscustomobject]@{
            terminalProfile = $TerminalProfile
        }
        projects = @($Project)
    }
    Assert-Registry -Registry $probe
}

function Merge-ProjectManifest {
    param(
        [Parameter(Mandatory)] $Project,
        [Parameter(Mandatory)] $ManifestInfo,
        [Parameter(Mandatory)][string] $TerminalProfile,
        [switch] $KeepRequestedIcon
    )

    $manifest = $ManifestInfo.data
    $resolved = $Project | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100

    if ($manifest.PSObject.Properties.Name -contains 'repository') {
        Set-ObjectProperty -Object $resolved -Name 'repository' -Value $manifest.repository
    }
    if ($manifest.PSObject.Properties.Name -contains 'presentation') {
        if (
            $manifest.presentation.PSObject.Properties.Name -contains 'accent'
        ) {
            $resolved.presentation.accent = $manifest.presentation.accent
        }
        if (
            -not $KeepRequestedIcon -and
            $manifest.presentation.PSObject.Properties.Name -contains 'icon'
        ) {
            $resolved.presentation.icon = $manifest.presentation.icon
        }
    }
    if ($manifest.PSObject.Properties.Name -contains 'requirements') {
        Set-ObjectProperty `
            -Object $resolved `
            -Name 'requirements' `
            -Value $manifest.requirements
    }

    $disabled = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    if ($manifest.PSObject.Properties.Name -contains 'disabledTasks') {
        foreach ($taskId in @($manifest.disabledTasks)) {
            [void] $disabled.Add([string] $taskId)
        }
        if ($disabled.Contains('main')) {
            throw "Задачу 'main' отключить нельзя."
        }
    }

    if ($manifest.PSObject.Properties.Name -contains 'tasks') {
        foreach ($taskProperty in $manifest.tasks.PSObject.Properties) {
            $taskId = $taskProperty.Name
            if ($disabled.Contains($taskId)) {
                throw "Задача '$taskId' одновременно изменена и отключена."
            }
            $patch = $taskProperty.Value
            Assert-ManifestTaskPatch `
                -Root $resolved.root `
                -TaskId $taskId `
                -Patch $patch

            $matches = @($resolved.tasks | Where-Object {
                $_.id.Equals($taskId, [StringComparison]::OrdinalIgnoreCase)
            })
            if ($matches.Count -gt 1) {
                throw "Задача '$taskId' повторяется в базовом проекте."
            }
            if ($matches.Count -eq 1) {
                $resolvedTask = $matches[0]
            }
            else {
                $resolvedTask = [pscustomobject][ordered]@{ id = $taskId }
                $resolved.tasks = @($resolved.tasks) + @($resolvedTask)
            }
            foreach ($property in $patch.PSObject.Properties) {
                Set-ObjectProperty `
                    -Object $resolvedTask `
                    -Name $property.Name `
                    -Value $property.Value
            }
        }
    }

    if ($disabled.Count -gt 0) {
        $resolved.tasks = @($resolved.tasks | Where-Object {
            -not $disabled.Contains([string] $_.id)
        })
        if ($manifest.PSObject.Properties.Name -notcontains 'palette') {
            $resolved.palette = @($resolved.palette | Where-Object {
                -not $disabled.Contains([string] $_)
            })
        }
        if ($manifest.PSObject.Properties.Name -notcontains 'workspace') {
            $resolved.workspace = @($resolved.workspace | Where-Object {
                -not $disabled.Contains([string] $_.task)
            })
        }
    }

    if ($manifest.PSObject.Properties.Name -contains 'palette') {
        $resolved.palette = @($manifest.palette)
    }
    if ($manifest.PSObject.Properties.Name -contains 'workspace') {
        $resolved.workspace = @($manifest.workspace)
    }

    Set-ObjectProperty -Object $resolved -Name 'manifest' -Value (
        [pscustomobject][ordered]@{
            path = '.el-project.json'
            sha256 = $ManifestInfo.hash
            importedAt = [DateTime]::UtcNow.ToString('o')
        }
    )
    Assert-ProjectSnapshot `
        -Project $resolved `
        -TerminalProfile $TerminalProfile
    return $resolved
}

function Resolve-ProjectDefinition {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $TerminalProfile,
        [string] $RequestedName,
        [string] $RequestedStack,
        [string] $RequestedIcon,
        [switch] $AssumeYes,
        [switch] $GitTrusted
    )

    $manifestInfo = Read-ProjectManifest -Root $Root
    $manifest = if ($manifestInfo) { $manifestInfo.data } else { $null }

    $displayName = if ($RequestedName) {
        $RequestedName.Trim()
    }
    elseif (
        $manifest -and
        $manifest.PSObject.Properties.Name -contains 'displayName'
    ) {
        [string] $manifest.displayName
    }
    else {
        Split-Path -Leaf $Root
    }
    if (
        [string]::IsNullOrWhiteSpace($displayName) -or
        -not (Test-SafeText -Value $displayName -MaximumLength 80)
    ) {
        throw 'Имя проекта пустое или содержит управляющие символы.'
    }

    $effectiveStack = if ($RequestedStack) {
        $RequestedStack
    }
    elseif (
        $manifest -and
        $manifest.PSObject.Properties.Name -contains 'stack'
    ) {
        [string] $manifest.stack
    }
    else {
        $candidates = @(Get-StackCandidates -Root $Root)
        Select-DetectedStack -Candidates $candidates -AssumeYes:$AssumeYes
    }

    $project = New-DetectedProject `
        -Root $Root `
        -DisplayName $displayName `
        -Id $Id `
        -DetectedStack $effectiveStack `
        -Repository (Get-RepositoryUrl -Root $Root -Trusted:$GitTrusted) `
        -RequestedIcon $RequestedIcon `
        -GitTrusted:$GitTrusted

    if ($manifestInfo) {
        $project = Merge-ProjectManifest `
            -Project $project `
            -ManifestInfo $manifestInfo `
            -TerminalProfile $TerminalProfile `
            -KeepRequestedIcon:([bool] $RequestedIcon)
    }
    else {
        Assert-ProjectSnapshot `
            -Project $project `
            -TerminalProfile $TerminalProfile
    }

    return [pscustomobject][ordered]@{
        project = $project
        manifestInfo = $manifestInfo
    }
}

function New-DetectedProject {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $DisplayName,
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $DetectedStack,
        [string] $Repository,
        [string] $RequestedIcon,
        [switch] $GitTrusted
    )

    $isGit = Test-GitRepository -Root $Root -Trusted:$GitTrusted
    $tasks = [Collections.Generic.List[object]]::new()
    $mainSteps = [Collections.Generic.List[object]]::new()
    if ($isGit) {
        $mainSteps.Add((New-Step -Runner 'gitStatus' -Properties @{}))
    }
    $mainSteps.Add((New-Step -Runner 'message' -Properties @{
        text = 'Готово к разработке.'
    }))
    $tasks.Add((New-Task `
        -Id 'main' `
        -Label 'Открыть консоль проекта' `
        -TabTitle "$DisplayName · Dev" `
        -Icon '›' `
        -Steps @($mainSteps)))

    $palette = [Collections.Generic.List[string]]::new()
    $workspaceTasks = [Collections.Generic.List[string]]::new()
    $workspaceTasks.Add('main')
    $accent = 'Blue'
    $defaultIcon = '▣'

    switch ($DetectedStack) {
        'pwa' {
            $accent = 'Cyan'
            $defaultIcon = '◫'
            $frontendTestStep = $null
            $apiTestStep = $null

            $packagePath = Join-Path $Root 'package.json'
            if (Test-Path -LiteralPath $packagePath -PathType Leaf) {
                $package = Read-PackageManifest -Path $packagePath -Name 'package.json'
                $manager = Get-PackageManager -Root $Root
                $scriptNames = @(Get-PackageScriptNames -Package $package)

                if ($scriptNames -contains 'test') {
                    $frontendTestStep = New-Step -Runner 'packageScript' -Properties @{
                        manager = $manager
                        script = 'test'
                        arguments = @()
                    }
                    $tasks.Add((New-Task `
                        -Id 'frontend-tests' `
                        -Label 'Проверить PWA-клиент' `
                        -TabTitle "$DisplayName · PWA tests" `
                        -Icon '✓' `
                        -Steps @($frontendTestStep)))
                    $palette.Add('frontend-tests')
                    $workspaceTasks.Add('frontend-tests')
                }

                if ($scriptNames -contains 'test:api') {
                    $apiTestStep = New-Step -Runner 'packageScript' -Properties @{
                        manager = $manager
                        script = 'test:api'
                        arguments = @()
                    }
                }
            }

            $backendRoot = Join-Path $Root 'backend'
            $backendPackagePath = Join-Path $backendRoot 'package.json'
            if (Test-Path -LiteralPath $backendPackagePath -PathType Leaf) {
                $backendPackage = Read-PackageManifest `
                    -Path $backendPackagePath `
                    -Name 'backend/package.json'
                $backendManager = Get-PackageManager -Root $backendRoot
                $backendScripts = @(Get-PackageScriptNames -Package $backendPackage)

                if (-not $apiTestStep -and $backendScripts -contains 'test') {
                    $apiTestStep = New-Step -Runner 'packageScript' -Properties @{
                        manager = $backendManager
                        script = 'test'
                        arguments = @()
                        cwd = 'backend'
                    }
                }

                if ($backendScripts -contains 'build') {
                    $tasks.Add((New-Task `
                        -Id 'backend-build' `
                        -Label 'Собрать TypeScript API' `
                        -TabTitle "$DisplayName · API build" `
                        -Icon '◆' `
                        -Steps @((New-Step -Runner 'packageScript' -Properties @{
                            manager = $backendManager
                            script = 'build'
                            arguments = @()
                            cwd = 'backend'
                        }))))
                    $palette.Add('backend-build')
                }
            }

            if ($apiTestStep) {
                $tasks.Add((New-Task `
                    -Id 'api-tests' `
                    -Label 'Проверить TypeScript API' `
                    -TabTitle "$DisplayName · API tests" `
                    -Icon '✓' `
                    -Steps @($apiTestStep)))
                $palette.Add('api-tests')
                if ($workspaceTasks.Count -lt 3) {
                    $workspaceTasks.Add('api-tests')
                }
            }

            if ($frontendTestStep -and $apiTestStep) {
                $tasks.Add((New-Task `
                    -Id 'full-tests' `
                    -Label 'Запустить все тесты' `
                    -TabTitle "$DisplayName · Full tests" `
                    -Icon '✓' `
                    -Steps @($frontendTestStep, $apiTestStep)))
                $palette.Add('full-tests')
            }
        }
        'compose' {
            $accent = 'DarkCyan'
            $defaultIcon = '◈'
            $workspaceTasks.Clear()
            $workspaceTasks.Add('main')
            $backendTestStep = $null
            $frontendTestStep = $null

            $backendRoot = Join-Path $Root 'backend'
            if (Test-Path -LiteralPath $backendRoot -PathType Container) {
                $tasks.Add((New-Task `
                    -Id 'backend-shell' `
                    -Label 'Консоль backend' `
                    -TabTitle "$DisplayName · Backend" `
                    -Icon '◆' `
                    -Steps @((New-Step -Runner 'workspaceShell' -Properties @{
                        cwd = 'backend'
                    }))))
                if ($workspaceTasks.Count -lt 3) {
                    $workspaceTasks.Add('backend-shell')
                }

                $backendRequirements = @(
                    Get-ChildItem `
                        -LiteralPath $backendRoot `
                        -Filter 'requirements*.txt' `
                        -File `
                        -ErrorAction SilentlyContinue |
                        ForEach-Object {
                            Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
                        }
                ) -join [Environment]::NewLine
                if (
                    (Test-Path -LiteralPath (Join-Path $backendRoot 'app\main.py') -PathType Leaf) -and
                    $backendRequirements -match '(?im)^\s*uvicorn(?:\[|[=<>!~]|\s|$)'
                ) {
                    $tasks.Add((New-Task `
                        -Id 'backend-dev' `
                        -Label 'Запустить FastAPI backend' `
                        -TabTitle "$DisplayName · API" `
                        -Icon '▶' `
                        -Steps @((New-Step -Runner 'pythonModule' -Properties @{
                            module = 'uvicorn'
                            arguments = @(
                                'app.main:app',
                                '--reload',
                                '--host',
                                '127.0.0.1',
                                '--port',
                                '8000'
                            )
                            cwd = 'backend'
                        }))))
                    $palette.Add('backend-dev')
                }

                if (Test-Path -LiteralPath (Join-Path $backendRoot 'tests') -PathType Container) {
                    $backendTestStep = New-Step -Runner 'pythonModule' -Properties @{
                        module = 'pytest'
                        arguments = @('-q', 'tests')
                        cwd = 'backend'
                    }
                    $tasks.Add((New-Task `
                        -Id 'backend-tests' `
                        -Label 'Проверить backend' `
                        -TabTitle "$DisplayName · Backend tests" `
                        -Icon '✓' `
                        -Steps @($backendTestStep) `
                        -Environment @{ PYTHONDONTWRITEBYTECODE = '1' }))
                    $palette.Add('backend-tests')
                }
            }

            $frontendRoot = Join-Path $Root 'frontend'
            $frontendPackagePath = Join-Path $frontendRoot 'package.json'
            if (Test-Path -LiteralPath $frontendPackagePath -PathType Leaf) {
                $tasks.Add((New-Task `
                    -Id 'frontend-shell' `
                    -Label 'Консоль frontend' `
                    -TabTitle "$DisplayName · Frontend" `
                    -Icon '◇' `
                    -Steps @((New-Step -Runner 'workspaceShell' -Properties @{
                        cwd = 'frontend'
                    }))))
                if ($workspaceTasks.Count -lt 3) {
                    $workspaceTasks.Add('frontend-shell')
                }

                $frontendPackage = Read-PackageManifest `
                    -Path $frontendPackagePath `
                    -Name 'frontend/package.json'
                $frontendManager = Get-PackageManager -Root $frontendRoot
                $frontendScripts = @(Get-PackageScriptNames -Package $frontendPackage)

                if ($frontendScripts -contains 'dev') {
                    $tasks.Add((New-Task `
                        -Id 'frontend-dev' `
                        -Label 'Запустить frontend' `
                        -TabTitle "$DisplayName · Frontend dev" `
                        -Icon '▶' `
                        -Steps @((New-Step -Runner 'packageScript' -Properties @{
                            manager = $frontendManager
                            script = 'dev'
                            arguments = @()
                            cwd = 'frontend'
                        }))))
                    $palette.Add('frontend-dev')
                }
                if ($frontendScripts -contains 'test') {
                    $frontendTestStep = New-Step -Runner 'packageScript' -Properties @{
                        manager = $frontendManager
                        script = 'test'
                        arguments = @()
                        cwd = 'frontend'
                    }
                    $tasks.Add((New-Task `
                        -Id 'frontend-tests' `
                        -Label 'Проверить frontend' `
                        -TabTitle "$DisplayName · Frontend tests" `
                        -Icon '✓' `
                        -Steps @($frontendTestStep)))
                    $palette.Add('frontend-tests')
                }
                if ($frontendScripts -contains 'lint') {
                    $tasks.Add((New-Task `
                        -Id 'frontend-checks' `
                        -Label 'Проверить frontend lint' `
                        -TabTitle "$DisplayName · Frontend checks" `
                        -Icon '✓' `
                        -Steps @((New-Step -Runner 'packageScript' -Properties @{
                            manager = $frontendManager
                            script = 'lint'
                            arguments = @()
                            cwd = 'frontend'
                        }))))
                    $palette.Add('frontend-checks')
                }
                if ($frontendScripts -contains 'build') {
                    $tasks.Add((New-Task `
                        -Id 'frontend-build' `
                        -Label 'Собрать frontend' `
                        -TabTitle "$DisplayName · Frontend build" `
                        -Icon '◆' `
                        -Steps @((New-Step -Runner 'packageScript' -Properties @{
                            manager = $frontendManager
                            script = 'build'
                            arguments = @()
                            cwd = 'frontend'
                        }))))
                    $palette.Add('frontend-build')
                }
            }

            if ($backendTestStep -and $frontendTestStep) {
                $tasks.Add((New-Task `
                    -Id 'full-tests' `
                    -Label 'Проверить backend и frontend' `
                    -TabTitle "$DisplayName · Full tests" `
                    -Icon '✓' `
                    -Steps @($backendTestStep, $frontendTestStep) `
                    -Environment @{ PYTHONDONTWRITEBYTECODE = '1' }))
                $palette.Add('full-tests')
            }

            # Compose actions are explicit and appear only when Docker is
            # installed. Opening the workspace never starts containers.
            if (Get-Command docker -ErrorAction SilentlyContinue) {
                foreach ($composeTask in @(
                    [pscustomobject]@{
                        id = 'compose-status'
                        label = 'Показать состояние Compose'
                        title = "$DisplayName · Compose status"
                        icon = '◉'
                        arguments = @('compose', 'ps')
                    },
                    [pscustomobject]@{
                        id = 'compose-up'
                        label = 'Запустить Docker Compose'
                        title = "$DisplayName · Compose up"
                        icon = '▶'
                        arguments = @('compose', 'up', '-d')
                    },
                    [pscustomobject]@{
                        id = 'compose-logs'
                        label = 'Показать последние логи Compose'
                        title = "$DisplayName · Compose logs"
                        icon = '≡'
                        arguments = @('compose', 'logs', '--tail', '100')
                    }
                )) {
                    $tasks.Add((New-Task `
                        -Id $composeTask.id `
                        -Label $composeTask.label `
                        -TabTitle $composeTask.title `
                        -Icon $composeTask.icon `
                        -Steps @((New-Step -Runner 'installedTool' -Properties @{
                            name = 'docker'
                            arguments = @($composeTask.arguments)
                        }))))
                    $palette.Add($composeTask.id)
                }
            }
        }
        'node' {
            $accent = 'Magenta'
            $defaultIcon = '◇'
            $packagePath = Join-Path $Root 'package.json'
            $package = Read-PackageManifest -Path $packagePath -Name 'package.json'
            $manager = Get-PackageManager -Root $Root
            $scriptNames = @(Get-PackageScriptNames -Package $package)
            $hasTypeScriptDependency = $false
            foreach ($dependencyGroup in @('dependencies', 'devDependencies')) {
                if (
                    $package.PSObject.Properties.Name -contains $dependencyGroup -and
                    $package.$dependencyGroup -and
                    $package.$dependencyGroup.PSObject.Properties.Name -contains 'typescript'
                ) {
                    $hasTypeScriptDependency = $true
                    break
                }
            }

            if ($scriptNames -contains 'dev') {
                $tasks.Add((New-Task `
                    -Id 'dev' `
                    -Label 'Запустить dev-сервер' `
                    -TabTitle "$DisplayName · Dev server" `
                    -Icon '▶' `
                    -Steps @((New-Step -Runner 'packageScript' -Properties @{
                        manager = $manager
                        script = 'dev'
                        arguments = @()
                    }))))
                $workspaceTasks.Clear()
                $workspaceTasks.Add('dev')
                $workspaceTasks.Add('main')
                $palette.Add('dev')
            }

            if ($scriptNames -contains 'test') {
                $tasks.Add((New-Task `
                    -Id 'tests' `
                    -Label 'Запустить тесты' `
                    -TabTitle "$DisplayName · Tests" `
                    -Icon '✓' `
                    -Steps @((New-Step -Runner 'packageScript' -Properties @{
                        manager = $manager
                        script = 'test'
                        arguments = @()
                    }))))
                $palette.Add('tests')
            }

            $checkSteps = [Collections.Generic.List[object]]::new()
            if ($scriptNames -contains 'lint') {
                $checkSteps.Add((New-Step -Runner 'packageScript' -Properties @{
                    manager = $manager
                    script = 'lint'
                    arguments = @()
                }))
            }
            if ($scriptNames -contains 'typecheck') {
                $checkSteps.Add((New-Step -Runner 'packageScript' -Properties @{
                    manager = $manager
                    script = 'typecheck'
                    arguments = @()
                }))
            }
            elseif (
                (Test-Path -LiteralPath (Join-Path $Root 'tsconfig.json') -PathType Leaf) -and
                (
                    (Test-Path -LiteralPath (Join-Path $Root 'node_modules\.bin\tsc.cmd') -PathType Leaf) -or
                    $hasTypeScriptDependency
                )
            ) {
                $checkSteps.Add((New-Step -Runner 'packageBinary' -Properties @{
                    name = 'tsc'
                    arguments = @('--noEmit')
                }))
            }
            if ($checkSteps.Count -gt 0) {
                $tasks.Add((New-Task `
                    -Id 'checks' `
                    -Label 'Запустить проверки' `
                    -TabTitle "$DisplayName · Checks" `
                    -Icon '✓' `
                    -Steps @($checkSteps)))
                $palette.Add('checks')
            }

            if ($scriptNames -contains 'build') {
                $tasks.Add((New-Task `
                    -Id 'build' `
                    -Label 'Собрать проект' `
                    -TabTitle "$DisplayName · Build" `
                    -Icon '◆' `
                    -Steps @((New-Step -Runner 'packageScript' -Properties @{
                        manager = $manager
                        script = 'build'
                        arguments = @()
                    }))))
                $palette.Add('build')
            }

            if ($workspaceTasks.Count -lt 3) {
                if (@($tasks.id) -contains 'checks') {
                    $workspaceTasks.Add('checks')
                }
                elseif (@($tasks.id) -contains 'tests') {
                    $workspaceTasks.Add('tests')
                }
            }
        }
        'python' {
            $accent = 'Yellow'
            $defaultIcon = '◆'
            $testsRoot = Join-Path $Root 'tests'
            if (Test-Path -LiteralPath $testsRoot -PathType Container) {
                $usePytest =
                    (Test-Path -LiteralPath (Join-Path $Root 'pytest.ini') -PathType Leaf) -or
                    (Test-Path -LiteralPath (Join-Path $Root 'conftest.py') -PathType Leaf)
                if (-not $usePytest -and
                    (Test-Path -LiteralPath (Join-Path $Root 'pyproject.toml') -PathType Leaf)) {
                    $pyprojectText = Get-Content -LiteralPath (Join-Path $Root 'pyproject.toml') -Raw
                    $usePytest = $pyprojectText -match '(?im)^\s*\[tool\.pytest' -or
                        $pyprojectText -match '(?i)\bpytest\b'
                }

                if ($usePytest) {
                    $testStep = New-Step -Runner 'pythonModule' -Properties @{
                        module = 'pytest'
                        arguments = @('-q')
                    }
                }
                else {
                    $testStep = New-Step -Runner 'pythonModule' -Properties @{
                        module = 'unittest'
                        arguments = @('discover', '-s', 'tests', '-v')
                    }
                }
                $tasks.Add((New-Task `
                    -Id 'tests' `
                    -Label 'Запустить тесты' `
                    -TabTitle "$DisplayName · Tests" `
                    -Icon '✓' `
                    -Steps @($testStep) `
                    -Environment @{ PYTHONDONTWRITEBYTECODE = '1' }))
                $palette.Add('tests')
                $workspaceTasks.Add('tests')
            }
        }
        'dotnet' {
            $accent = 'Magenta'
            $defaultIcon = '◈'
            $tasks.Add((New-Task `
                -Id 'tests' `
                -Label 'Запустить тесты' `
                -TabTitle "$DisplayName · Tests" `
                -Icon '✓' `
                -Steps @((New-Step -Runner 'dotnet' -Properties @{
                    verb = 'test'
                    arguments = @()
                }))))
            $tasks.Add((New-Task `
                -Id 'build' `
                -Label 'Собрать проект' `
                -TabTitle "$DisplayName · Build" `
                -Icon '◆' `
                -Steps @((New-Step -Runner 'dotnet' -Properties @{
                    verb = 'build'
                    arguments = @()
                }))))
            $palette.Add('tests')
            $palette.Add('build')
            $workspaceTasks.Add('tests')
        }
        'rust' {
            $accent = 'Red'
            $defaultIcon = '⚙'
            $tasks.Add((New-Task `
                -Id 'tests' `
                -Label 'Запустить тесты' `
                -TabTitle "$DisplayName · Tests" `
                -Icon '✓' `
                -Steps @((New-Step -Runner 'cargo' -Properties @{
                    verb = 'test'
                    arguments = @()
                }))))
            $tasks.Add((New-Task `
                -Id 'checks' `
                -Label 'Запустить cargo check' `
                -TabTitle "$DisplayName · Checks" `
                -Icon '◇' `
                -Steps @((New-Step -Runner 'cargo' -Properties @{
                    verb = 'check'
                    arguments = @()
                }))))
            $palette.Add('tests')
            $palette.Add('checks')
            $workspaceTasks.Add('tests')
            $workspaceTasks.Add('checks')
        }
        'go' {
            $accent = 'Cyan'
            $defaultIcon = '◉'
            $tasks.Add((New-Task `
                -Id 'tests' `
                -Label 'Запустить go test' `
                -TabTitle "$DisplayName · Tests" `
                -Icon '✓' `
                -Steps @((New-Step -Runner 'go' -Properties @{
                    verb = 'test'
                    arguments = @('./...')
                }))))
            $tasks.Add((New-Task `
                -Id 'checks' `
                -Label 'Запустить go vet' `
                -TabTitle "$DisplayName · Checks" `
                -Icon '◇' `
                -Steps @((New-Step -Runner 'go' -Properties @{
                    verb = 'vet'
                    arguments = @('./...')
                }))))
            $palette.Add('tests')
            $palette.Add('checks')
            $workspaceTasks.Add('tests')
            $workspaceTasks.Add('checks')
        }
    }

    Add-RepositoryTask `
        -Tasks $tasks `
        -Repository $Repository `
        -DisplayName $DisplayName `
        -IsGit $isGit
    if ($Repository) {
        $palette.Add('repository')
    }

    $projectIcon = if ($RequestedIcon) { $RequestedIcon } else { $defaultIcon }
    $project = [ordered]@{
        id = $Id
        displayName = $DisplayName
        root = $Root
        stack = $DetectedStack
        repository = $Repository
        trusted = $true
        presentation = [pscustomobject][ordered]@{
            accent = $accent
            icon = $projectIcon
        }
        tasks = @($tasks)
        palette = @($palette)
        workspace = @(New-AutomaticWorkspace -TaskIds @($workspaceTasks))
    }
    if ($GitTrusted) {
        $project['gitTrusted'] = $true
    }
    return [pscustomobject] $project
}

function Get-StepDescription {
    param([Parameter(Mandatory)] $Step)

    $workingDirectory = if ($Step.PSObject.Properties.Name -contains 'cwd') {
        "$($Step.cwd)> "
    }
    else {
        ''
    }

    switch ($Step.runner) {
        'gitStatus' { return "${workingDirectory}git status --short --branch" }
        'workspaceShell' { return "open shell: $($Step.cwd)" }
        'pythonModule' {
            return (
                "${workingDirectory}python -m $($Step.module) " +
                "$(@($Step.arguments) -join ' ')"
            ).Trim()
        }
        'packageScript' {
            return "${workingDirectory}$($Step.manager) run $($Step.script)"
        }
        'packageBinary' {
            return (
                "${workingDirectory}local $($Step.name) " +
                "$(@($Step.arguments) -join ' ')"
            ).Trim()
        }
        'dotnet' {
            return (
                "${workingDirectory}dotnet $($Step.verb) " +
                "$(@($Step.arguments) -join ' ')"
            ).Trim()
        }
        'cargo' {
            return (
                "${workingDirectory}cargo $($Step.verb) " +
                "$(@($Step.arguments) -join ' ')"
            ).Trim()
        }
        'go' {
            return (
                "${workingDirectory}go $($Step.verb) " +
                "$(@($Step.arguments) -join ' ')"
            ).Trim()
        }
        'installedTool' {
            return (
                "${workingDirectory}$($Step.name) " +
                "$(@($Step.arguments) -join ' ')"
            ).Trim()
        }
        'openRepository' { return 'open repository URL' }
        'message' { return "message: $($Step.text)" }
        default { return $Step.runner }
    }
}

function Get-ProjectStackLabel {
    param([Parameter(Mandatory)] $Project)

    switch ($Project.stack) {
        'compose' {
            $parts = [Collections.Generic.List[string]]::new()
            $parts.Add('Docker Compose')

            $backendRoot = Join-Path $Project.root 'backend'
            if (Test-PythonProjectMarker -Root $backendRoot) {
                $backendLabel = 'Python API'
                try {
                    $requirementsText = @(
                        Get-ChildItem `
                            -LiteralPath $backendRoot `
                            -Filter 'requirements*.txt' `
                            -File `
                            -ErrorAction SilentlyContinue |
                            ForEach-Object {
                                Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
                            }
                    ) -join [Environment]::NewLine
                    if ($requirementsText -match '(?im)^\s*fastapi(?:[=<>!~]|\s|$)') {
                        $backendLabel = 'Python/FastAPI'
                    }
                }
                catch {
                    # Keep the stable Python label when requirements are unreadable.
                }
                $parts.Add($backendLabel)
            }

            $frontendPackagePath = Join-Path $Project.root 'frontend\package.json'
            if (Test-Path -LiteralPath $frontendPackagePath -PathType Leaf) {
                $frontendLabel = 'Node.js frontend'
                try {
                    $frontendPackage = Read-PackageManifest `
                        -Path $frontendPackagePath `
                        -Name 'frontend/package.json'
                    $dependencyNames = @(
                        @($frontendPackage.dependencies.PSObject.Properties.Name) +
                        @($frontendPackage.devDependencies.PSObject.Properties.Name)
                    )
                    if ($dependencyNames -contains 'react' -and
                        $dependencyNames -contains 'vite') {
                        $frontendLabel = 'React/Vite'
                    }
                    elseif ($dependencyNames -contains 'react') {
                        $frontendLabel = 'React'
                    }
                }
                catch {
                    # Keep the stable Node.js label when package.json is unreadable.
                }
                $parts.Add($frontendLabel)
            }

            $composePath = Get-ComposeFilePath -Root $Project.root
            if ($composePath) {
                try {
                    $composeText = Get-Content -LiteralPath $composePath -Raw -Encoding UTF8
                    if ($composeText -match '(?im)\bpostgres(?:ql)?\b') {
                        $parts.Add('PostgreSQL')
                    }
                }
                catch {
                    # The stack label remains useful without parsing Compose content.
                }
            }
            return $parts -join ' · '
        }
        'pwa' {
            $parts = [Collections.Generic.List[string]]::new()
            $parts.Add('PWA')
            $parts.Add('JavaScript')

            $backendPackagePath = Join-Path $Project.root 'backend\package.json'
            if (Test-Path -LiteralPath $backendPackagePath -PathType Leaf) {
                try {
                    $backendPackage = Get-Content `
                        -LiteralPath $backendPackagePath `
                        -Raw `
                        -Encoding UTF8 | ConvertFrom-Json -Depth 30
                    $usesFastify =
                        $backendPackage.PSObject.Properties.Name -contains 'dependencies' -and
                        $backendPackage.dependencies -and
                        $backendPackage.dependencies.PSObject.Properties.Name -contains 'fastify'
                    $usesTypeScript =
                        $backendPackage.PSObject.Properties.Name -contains 'devDependencies' -and
                        $backendPackage.devDependencies -and
                        $backendPackage.devDependencies.PSObject.Properties.Name -contains 'typescript'
                    if ($usesFastify -and $usesTypeScript) {
                        $parts.Add('TypeScript/Fastify')
                    }
                    elseif ($usesTypeScript) {
                        $parts.Add('TypeScript/Node.js API')
                    }
                    else {
                        $parts.Add('Node.js API')
                    }
                }
                catch {
                    $parts.Add('Node.js API')
                }
            }

            $composePath = @(
                (Join-Path $Project.root 'compose.yaml'),
                (Join-Path $Project.root 'compose.yml'),
                (Join-Path $Project.root 'docker-compose.yaml'),
                (Join-Path $Project.root 'docker-compose.yml')
            ) | Where-Object {
                Test-Path -LiteralPath $_ -PathType Leaf
            } | Select-Object -First 1
            if ($composePath) {
                try {
                    $composeText = Get-Content -LiteralPath $composePath -Raw -Encoding UTF8
                    if ($composeText -match '(?im)\bpostgres(?:ql)?\b') {
                        $parts.Add('PostgreSQL')
                    }
                    if ($composeText -match '(?im)\bminio\b') {
                        $parts.Add('MinIO')
                    }
                }
                catch {
                    # The stable product type remains useful even if compose is unreadable.
                }
                if (
                    (Test-Path -LiteralPath (Join-Path $Project.root 'deploy\Caddyfile') `
                        -PathType Leaf) -or
                    (Test-Path -LiteralPath (Join-Path $Project.root 'Caddyfile') `
                        -PathType Leaf)
                ) {
                    $parts.Add('Caddy')
                }
                $parts.Add('Docker')
            }
            return $parts -join ' · '
        }
        'node' { return 'Node.js' }
        'python' { return 'Python' }
        'dotnet' { return '.NET' }
        'rust' { return 'Rust' }
        'go' { return 'Go' }
        default { return 'Generic' }
    }
}

function Get-ProjectStackShortLabel {
    param([Parameter(Mandatory)] $Project)

    switch ($Project.stack) {
        'compose' { return 'Docker Compose' }
        'pwa' { return 'Full-stack PWA' }
        'node' { return 'Node.js' }
        'python' { return 'Python' }
        'dotnet' { return '.NET' }
        'rust' { return 'Rust' }
        'go' { return 'Go' }
        default { return 'Generic' }
    }
}

function Get-GitAccessWarning {
    param([Parameter(Mandatory)][string] $Root)

    $gitMetadata = Join-Path $Root '.git'
    if (
        -not (Test-Path -LiteralPath $gitMetadata) -or
        (Test-GitRepository -Root $Root)
    ) {
        return $null
    }

    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $git) {
        return 'метаданные .git найдены, но git.exe недоступен'
    }

    try {
        $global:LASTEXITCODE = 0
        $output = @(
            & $git.Source -C $Root rev-parse --is-inside-work-tree 2>&1
        ) -join [Environment]::NewLine
        if ($LASTEXITCODE -ne 0 -and $output -match 'dubious ownership') {
            return (
                'Git не доверяет владельцу каталога (dubious ownership); ' +
                'Git-задачи пока не добавлены'
            )
        }
    }
    catch {
        # Keep the preview read-only and report a generic access issue below.
    }
    return 'метаданные .git найдены, но Git не может открыть репозиторий'
}

function Show-ProjectPreview {
    param([Parameter(Mandatory)] $Project)

    Write-Host
    Write-Host "  $($Project.presentation.icon)  $($Project.displayName)" `
        -ForegroundColor $Project.presentation.accent
    Write-Info "ID:    $($Project.id)"
    Write-Info "Стек:  $(Get-ProjectStackLabel -Project $Project)"
    Write-Info "Путь:  $($Project.root)"
    if ($Project.PSObject.Properties.Name -contains 'manifest') {
        Write-Info (
            "Manifest: $($Project.manifest.path) · " +
            "$($Project.manifest.sha256.Substring(0, 12))"
        )
    }
    if ($Project.repository) {
        Write-Info "Git:   $($Project.repository)"
    }
    else {
        $gitWarning = Get-GitAccessWarning -Root $Project.root
        if ($gitWarning) {
            Write-Host "  Git:   $gitWarning" -ForegroundColor Yellow
        }
    }
    Write-Host
    Write-Host '  Найденные задачи:' -ForegroundColor White
    foreach ($task in @($Project.tasks)) {
        $descriptions = @($task.steps | ForEach-Object { Get-StepDescription -Step $_ })
        Write-Host "  • $($task.id): $($descriptions -join ' → ')" -ForegroundColor DarkGray
    }
    Write-Host
    Write-Info 'На этом шаге ни одна задача не запускается.'
    Write-Host
}

function Confirm-Action {
    param(
        [Parameter(Mandatory)][string] $Prompt,
        [switch] $AssumeYes,
        [switch] $DefaultYes
    )

    if ($AssumeYes) {
        return $true
    }
    if ([Console]::IsInputRedirected) {
        throw 'Для неинтерактивного запуска добавьте -Yes.'
    }

    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    $answer = (Read-Host "  $Prompt $suffix").Trim()
    if (-not $answer) {
        return [bool] $DefaultYes
    }
    return $answer -match '^(?i:y|yes|д|да)$'
}

function Write-Registry {
    param([Parameter(Mandatory)] $Registry)

    Assert-Registry -Registry $Registry
    $content = ConvertTo-StableJson -Value $Registry
    [void] (Write-AtomicUtf8 `
        -Path $script:RegistryPath `
        -Content $content `
        -BackupPrefix 'projects')
}

function Set-RegistryUpdatedAt {
    param([Parameter(Mandatory)] $Registry)

    $value = [DateTime]::UtcNow.ToString('o')
    if ($Registry.PSObject.Properties.Name -contains 'updatedAt') {
        $Registry.updatedAt = $value
    }
    else {
        $Registry | Add-Member -NotePropertyName updatedAt -NotePropertyValue $value
    }
}

function Copy-RegistryObject {
    param([Parameter(Mandatory)] $Registry)

    return (($Registry | ConvertTo-Json -Depth 100) | ConvertFrom-Json -Depth 100)
}

function Commit-RegistryChange {
    param(
        [Parameter(Mandatory)] $OriginalRegistry,
        [Parameter(Mandatory)] $UpdatedRegistry
    )

    Assert-Registry -Registry $UpdatedRegistry
    $newRegistryContent = ConvertTo-StableJson -Value $UpdatedRegistry
    $newFragmentContent = ConvertTo-StableJson -Value (
        New-TerminalFragment -Registry $UpdatedRegistry
    )
    $oldRegistryContent = Get-FileContentOrNull -Path $script:RegistryPath
    $oldFragmentContent = Get-FileContentOrNull -Path $script:FragmentPath
    $journal = [ordered]@{
        schemaVersion = 1
        createdAt = [DateTime]::UtcNow.ToString('o')
        oldRegistryExisted = $null -ne $oldRegistryContent
        oldRegistryBase64 = if ($null -ne $oldRegistryContent) {
            [Convert]::ToBase64String(
                [Text.Encoding]::UTF8.GetBytes($oldRegistryContent)
            )
        }
        else {
            $null
        }
        oldFragmentExisted = $null -ne $oldFragmentContent
        oldFragmentBase64 = if ($null -ne $oldFragmentContent) {
            [Convert]::ToBase64String(
                [Text.Encoding]::UTF8.GetBytes($oldFragmentContent)
            )
        }
        else {
            $null
        }
        newRegistrySha256 = Get-ContentSha256 -Content $newRegistryContent
        newFragmentSha256 = Get-ContentSha256 -Content $newFragmentContent
    }
    [void] (Write-AtomicUtf8 `
        -Path $script:TransactionPath `
        -Content (ConvertTo-StableJson -Value $journal) `
        -BackupPrefix 'transaction-journal')

    try {
        [void] (Write-AtomicUtf8 `
            -Path $script:RegistryPath `
            -Content $newRegistryContent `
            -BackupPrefix 'projects')
        [void] (Write-AtomicUtf8 `
            -Path $script:FragmentPath `
            -Content $newFragmentContent `
            -BackupPrefix 'terminal-fragment')
        Remove-Item -LiteralPath $script:TransactionPath -Force
        Update-TerminalReloadSignal
        Write-Success 'Реестр и палитра обновлены транзакционно.'
    }
    catch {
        $commitFailure = $_.Exception
        try {
            Recover-PendingTransaction
        }
        catch {
            throw (
                'Ошибка обновления и автоматического rollback. Основная ошибка: ' +
                "$($commitFailure.Message). Rollback: $($_.Exception.Message)"
            )
        }
        throw $commitFailure
    }
}

function Invoke-AddProject {
    $path = if ($Target) { $Target } else { (Get-Location).Path }
    $root = Resolve-ProjectRoot -Path $path
    $registry = Read-Registry
    $originalRegistry = Copy-RegistryObject -Registry $registry

    foreach ($existing in @($registry.projects)) {
        if ([IO.Path]::GetFullPath($existing.root).TrimEnd('\', '/').Equals(
            $root,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Этот каталог уже зарегистрирован как '$($existing.id)'."
        }
    }

    $manifestInfo = Read-ProjectManifest -Root $root
    $displayName = if ($Name) {
        $Name.Trim()
    }
    elseif (
        $manifestInfo -and
        $manifestInfo.data.PSObject.Properties.Name -contains 'displayName'
    ) {
        [string] $manifestInfo.data.displayName
    }
    else {
        Split-Path -Leaf $root
    }
    if (-not (Test-SafeText -Value $displayName -MaximumLength 80) -or
        [string]::IsNullOrWhiteSpace($displayName)) {
        throw 'Имя проекта пустое или содержит управляющие символы.'
    }
    if ($Icon -and -not (Test-SafeText -Value $Icon -MaximumLength 8)) {
        throw 'Иконка проекта содержит недопустимые символы.'
    }

    $baseId = ConvertTo-ProjectId -DisplayName $displayName
    $id = $baseId
    $suffix = 2
    $ids = @($registry.projects.id)
    while ($ids -contains $id) {
        $suffixText = "-$suffix"
        $prefixLength = [Math]::Min($baseId.Length, 48 - $suffixText.Length)
        $id = $baseId.Substring(0, $prefixLength).TrimEnd('-') + $suffixText
        $suffix++
    }

    $resolvedDefinition = Resolve-ProjectDefinition `
        -Root $root `
        -Id $id `
        -TerminalProfile $registry.defaults.terminalProfile `
        -RequestedName $Name `
        -RequestedStack $Stack `
        -RequestedIcon $Icon `
        -AssumeYes:$Yes
    $project = $resolvedDefinition.project

    Show-ProjectPreview -Project $project
    if (
        $Yes -and
        $resolvedDefinition.manifestInfo -and
        (
            -not $TrustManifestHash -or
            -not $TrustManifestHash.Equals(
                $resolvedDefinition.manifestInfo.hash,
                [StringComparison]::OrdinalIgnoreCase
            )
        )
    ) {
        throw (
            'Для неинтерактивного импорта manifest укажите точный hash: ' +
            "-TrustManifestHash $($resolvedDefinition.manifestInfo.hash)"
        )
    }
    if (-not (Confirm-Action `
        -Prompt 'Добавить проект в EL-палитру?' `
        -AssumeYes:$Yes `
        -DefaultYes)) {
        Write-Info 'Добавление отменено.'
        return
    }

    $registry.projects = @($registry.projects) + @($project)
    Set-RegistryUpdatedAt -Registry $registry
    Commit-RegistryChange `
        -OriginalRegistry $originalRegistry `
        -UpdatedRegistry $registry
    Write-Success "Проект '$displayName' добавлен."
}

function Invoke-ListProjects {
    $registry = Read-Registry
    $rows = foreach ($project in @($registry.projects)) {
        [pscustomobject]@{
            ID = $project.id
            Name = $project.displayName
            Stack = Get-ProjectStackShortLabel -Project $project
            Status = if (Test-Path -LiteralPath $project.root -PathType Container) {
                'ready'
            }
            else {
                'path missing'
            }
            Path = $project.root
        }
    }

    if ($Json) {
        ConvertTo-Json -InputObject @($rows) -Depth 20
        return
    }

    Write-Host
    Write-Host '  EL PROJECTS' -ForegroundColor Blue
    $rows | Format-Table -AutoSize | Out-Host
    Write-Info "Всего: $(@($rows).Count)"
    Write-Host
}

function Invoke-RemoveProject {
    if (-not $Target) {
        throw 'Укажите ID или имя проекта: el-project remove <id>'
    }
    $registry = Read-Registry
    $originalRegistry = Copy-RegistryObject -Registry $registry
    $project = Get-Project -Registry $registry -Identity $Target

    Write-Host
    Write-Host "  Удалить из палитры: $($project.displayName)" -ForegroundColor Yellow
    Write-Info "Каталог останется на месте: $($project.root)"
    Write-Host
    if (-not (Confirm-Action `
        -Prompt 'Продолжить?' `
        -AssumeYes:$Yes)) {
        Write-Info 'Удаление отменено.'
        return
    }

    $registry.projects = @($registry.projects | Where-Object {
        -not $_.id.Equals($project.id, [StringComparison]::OrdinalIgnoreCase)
    })
    Set-RegistryUpdatedAt -Registry $registry
    Commit-RegistryChange `
        -OriginalRegistry $originalRegistry `
        -UpdatedRegistry $registry
    Write-Success "Проект '$($project.displayName)' убран из палитры."
    Write-Info 'Файлы проекта не изменялись.'
}

function Get-WtWorkspaceArguments {
    param(
        [Parameter(Mandatory)] $Registry,
        [Parameter(Mandatory)] $Project,
        [switch] $OnlyConsole
    )

    $panes = if ($OnlyConsole) {
        @([pscustomobject]@{ task = 'main'; action = 'newTab' })
    }
    else {
        @($Project.workspace)
    }
    if ($panes.Count -eq 0) {
        $panes = @([pscustomobject]@{ task = 'main'; action = 'newTab' })
    }

    $arguments = [Collections.Generic.List[string]]::new()
    $arguments.Add('-w')
    $arguments.Add('new')

    for ($index = 0; $index -lt $panes.Count; $index++) {
        $pane = $panes[$index]
        $task = Get-Task -Project $Project -TaskId $pane.task
        if ($index -gt 0) {
            $arguments.Add(';')
        }
        if ($pane.action -eq 'newTab') {
            $arguments.Add('new-tab')
        }
        else {
            $arguments.Add('split-pane')
            if ($pane.split -eq 'right') {
                $arguments.Add('--vertical')
            }
            else {
                $arguments.Add('--horizontal')
            }
            $arguments.Add('--size')
            $arguments.Add(([double] $pane.size).ToString(
                [Globalization.CultureInfo]::InvariantCulture
            ))
        }

        $arguments.Add('--profile')
        $arguments.Add([string] $Registry.defaults.terminalProfile)
        $arguments.Add('--startingDirectory')
        $arguments.Add([string] $Project.root)
        $arguments.Add('--title')
        $arguments.Add((Get-TerminalTaskTitle -Project $Project -Task $task))
        $arguments.Add('--tabColor')
        $arguments.Add((Get-TaskTabColor -Project $Project -Task $task))
        $arguments.Add('--suppressApplicationTitle')
        $arguments.Add('pwsh.exe')
        $arguments.Add('-NoLogo')
        $arguments.Add('-NoExit')
        $arguments.Add('-File')
        $arguments.Add($script:RunnerPath)
        $arguments.Add('-ProjectId')
        $arguments.Add([string] $Project.id)
        $arguments.Add('-TaskId')
        $arguments.Add([string] $task.id)
    }
    return @($arguments)
}

function Get-WtTaskArguments {
    param(
        [Parameter(Mandatory)] $Registry,
        [Parameter(Mandatory)] $Project,
        [Parameter(Mandatory)] $SelectedTask
    )

    $arguments = [Collections.Generic.List[string]]::new()
    $arguments.Add('-w')
    $arguments.Add($(if ($env:WT_SESSION) { '0' } else { 'new' }))
    $arguments.Add('new-tab')
    $arguments.Add('--profile')
    $arguments.Add([string] $Registry.defaults.terminalProfile)
    $arguments.Add('--startingDirectory')
    $arguments.Add([string] $Project.root)
    $arguments.Add('--title')
    $arguments.Add((Get-TerminalTaskTitle -Project $Project -Task $SelectedTask))
    $arguments.Add('--tabColor')
    $arguments.Add((Get-TaskTabColor -Project $Project -Task $SelectedTask))
    $arguments.Add('--suppressApplicationTitle')
    $arguments.Add('pwsh.exe')
    $arguments.Add('-NoLogo')
    $arguments.Add('-NoExit')
    $arguments.Add('-File')
    $arguments.Add($script:RunnerPath)
    $arguments.Add('-ProjectId')
    $arguments.Add([string] $Project.id)
    $arguments.Add('-TaskId')
    $arguments.Add([string] $SelectedTask.id)
    return @($arguments)
}

function Invoke-ListTasks {
    if (-not $Target) {
        throw 'Укажите проект: el-project tasks <id>'
    }
    $registry = Read-Registry
    $project = Get-Project -Registry $registry -Identity $Target
    $rows = foreach ($taskItem in @($project.tasks)) {
        [pscustomobject]@{
            ID = $taskItem.id
            Name = $taskItem.label
            Palette = if (@($project.palette) -contains $taskItem.id) { 'yes' } else { '' }
            Workspace = if (@($project.workspace.task) -contains $taskItem.id) { 'yes' } else { '' }
        }
    }
    if ($Json) {
        ConvertTo-Json -InputObject @($rows) -Depth 20
        return
    }
    Write-Host
    Write-Host "  $($project.presentation.icon)  $($project.displayName) · TASKS" `
        -ForegroundColor $project.presentation.accent
    $rows | Format-Table -AutoSize | Out-Host
}

function Invoke-RunTask {
    if (-not $Target -or -not $Task) {
        throw 'Использование: el-project run <project> <task>'
    }
    $registry = Read-Registry
    $project = Get-Project -Registry $registry -Identity $Target
    $selectedTask = Get-Task -Project $project -TaskId $Task
    if (-not (Test-Path -LiteralPath $project.root -PathType Container)) {
        throw "Каталог проекта не найден: $($project.root)"
    }
    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    if (-not $wt) {
        throw 'Windows Terminal (wt.exe) не найден.'
    }
    $arguments = @(Get-WtTaskArguments `
        -Registry $registry `
        -Project $project `
        -SelectedTask $selectedTask)
    if ($DryRun) {
        [pscustomobject]@{
            executable = $wt.Source
            arguments = $arguments
        } | ConvertTo-Json -Depth 20
        return
    }
    & $wt.Source @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Windows Terminal завершил запуск с кодом $LASTEXITCODE."
    }
    Write-Success "Запущено: $($project.displayName) / $($selectedTask.label)"
}

function Invoke-OpenProject {
    if (-not $Target) {
        throw 'Укажите ID или имя проекта: el-project open <id>'
    }
    $registry = Read-Registry
    $project = Get-Project -Registry $registry -Identity $Target
    if (-not (Test-Path -LiteralPath $project.root -PathType Container)) {
        throw "Каталог проекта не найден: $($project.root)"
    }

    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    if (-not $wt) {
        throw 'Windows Terminal (wt.exe) не найден.'
    }

    $arguments = @(Get-WtWorkspaceArguments `
        -Registry $registry `
        -Project $project `
        -OnlyConsole:$Console)
    if ($DryRun) {
        [pscustomobject]@{
            executable = $wt.Source
            arguments = $arguments
        } | ConvertTo-Json -Depth 20
        return
    }

    & $wt.Source @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Windows Terminal завершил запуск с кодом $LASTEXITCODE."
    }
    Write-Success "Открыт $($project.displayName)."
}

function Invoke-InspectProject {
    $path = if ($Target) { $Target } else { (Get-Location).Path }
    $root = Resolve-ProjectRoot -Path $path
    $registry = Read-Registry
    $manifestInfo = Read-ProjectManifest -Root $root
    $displayName = if ($Name) {
        $Name.Trim()
    }
    elseif (
        $manifestInfo -and
        $manifestInfo.data.PSObject.Properties.Name -contains 'displayName'
    ) {
        [string] $manifestInfo.data.displayName
    }
    else {
        Split-Path -Leaf $root
    }
    $id = ConvertTo-ProjectId -DisplayName $displayName
    $resolvedDefinition = Resolve-ProjectDefinition `
        -Root $root `
        -Id $id `
        -TerminalProfile $registry.defaults.terminalProfile `
        -RequestedName $Name `
        -RequestedStack $Stack `
        -RequestedIcon $Icon `
        -AssumeYes:$Yes
    $project = $resolvedDefinition.project

    if ($Json) {
        $project | ConvertTo-Json -Depth 100
    }
    else {
        Show-ProjectPreview -Project $project
    }
}

function Show-ProjectDiff {
    param(
        [Parameter(Mandatory)] $Before,
        [Parameter(Mandatory)] $After
    )

    $beforeTasks = @{}
    foreach ($taskItem in @($Before.tasks)) {
        $beforeTasks[$taskItem.id] = $taskItem
    }
    $afterTasks = @{}
    foreach ($taskItem in @($After.tasks)) {
        $afterTasks[$taskItem.id] = $taskItem
    }

    Write-Host
    Write-Host '  Изменения snapshot:' -ForegroundColor White
    $changes = 0
    foreach ($taskId in @($afterTasks.Keys | Sort-Object)) {
        if (-not $beforeTasks.ContainsKey($taskId)) {
            Write-Host "  + задача $taskId" -ForegroundColor Green
            $changes++
        }
        elseif (
            ($beforeTasks[$taskId] | ConvertTo-Json -Depth 30 -Compress) -ne
            ($afterTasks[$taskId] | ConvertTo-Json -Depth 30 -Compress)
        ) {
            Write-Host "  ~ задача $taskId" -ForegroundColor Yellow
            $changes++
        }
    }
    foreach ($taskId in @($beforeTasks.Keys | Sort-Object)) {
        if (-not $afterTasks.ContainsKey($taskId)) {
            Write-Host "  - задача $taskId" -ForegroundColor Red
            $changes++
        }
    }
    foreach ($propertyName in @(
        'displayName', 'stack', 'repository', 'presentation', 'palette', 'workspace'
    )) {
        $beforeValue = if ($Before.PSObject.Properties.Name -contains $propertyName) {
            $Before.$propertyName | ConvertTo-Json -Depth 30 -Compress
        }
        else {
            ''
        }
        $afterValue = if ($After.PSObject.Properties.Name -contains $propertyName) {
            $After.$propertyName | ConvertTo-Json -Depth 30 -Compress
        }
        else {
            ''
        }
        if ($beforeValue -ne $afterValue) {
            Write-Host "  ~ $propertyName" -ForegroundColor Yellow
            $changes++
        }
    }
    if ($changes -eq 0) {
        Write-Info 'Изменений нет.'
    }
    Write-Host
}

function Invoke-InitManifest {
    $path = if ($Target) { $Target } else { (Get-Location).Path }
    $root = Resolve-ProjectRoot -Path $path
    $manifestPath = Join-Path $root '.el-project.json'
    if (Test-Path -LiteralPath $manifestPath) {
        throw ".el-project.json уже существует: $manifestPath"
    }

    $registry = Read-Registry
    $displayName = if ($Name) { $Name.Trim() } else { Split-Path -Leaf $root }
    $candidates = @(Get-StackCandidates -Root $root)
    $detectedStack = Select-DetectedStack `
        -Candidates $candidates `
        -Requested $Stack `
        -AssumeYes:$Yes
    $project = New-DetectedProject `
        -Root $root `
        -DisplayName $displayName `
        -Id (ConvertTo-ProjectId -DisplayName $displayName) `
        -DetectedStack $detectedStack `
        -Repository (Get-RepositoryUrl -Root $root) `
        -RequestedIcon $Icon
    Assert-ProjectSnapshot `
        -Project $project `
        -TerminalProfile $registry.defaults.terminalProfile

    # PowerShell unwraps zero- and one-item pipeline results. Keep this value an
    # array so StrictMode can safely evaluate Count for every supported stack.
    $requiredCommands = @(@(switch ($detectedStack) {
        'pwa' { @('node', 'npm') }
        'compose' {
            'docker'
            $frontendRoot = Join-Path $root 'frontend'
            if (Test-Path -LiteralPath (Join-Path $frontendRoot 'package.json') -PathType Leaf) {
                'node'
                Get-PackageManager -Root $frontendRoot
            }
            if (Test-PythonProjectMarker -Root (Join-Path $root 'backend')) {
                'python'
            }
        }
        'node' { @('node', (Get-PackageManager -Root $root)) }
        'python' { @('python') }
        'dotnet' { @('dotnet') }
        'rust' { @('cargo') }
        'go' { @('go') }
        default { @() }
    }) | Select-Object -Unique)
    $manifest = [ordered]@{
        '$schema' = 'https://el-system-tools.local/schemas/el-project.schema.json'
        schemaVersion = 1
        displayName = $project.displayName
        stack = $project.stack
        presentation = [ordered]@{
            accent = $project.presentation.accent
            icon = $project.presentation.icon
        }
    }
    if (@($requiredCommands).Count -gt 0) {
        $manifest.requirements = [ordered]@{
            commands = @($requiredCommands)
        }
    }
    $content = ConvertTo-StableJson -Value $manifest

    Write-Host
    Write-Host '  Создать .el-project.json' -ForegroundColor Cyan
    Write-Info "Путь: $manifestPath"
    Write-Host
    Write-Host $content -ForegroundColor DarkGray
    if (-not (Confirm-Action `
        -Prompt 'Создать manifest?' `
        -AssumeYes:$Yes `
        -DefaultYes)) {
        Write-Info 'Создание отменено.'
        return
    }
    [void] (Write-AtomicUtf8 `
        -Path $manifestPath `
        -Content $content `
        -BackupPrefix "manifest-$($project.id)")
    Write-Success "Создан $manifestPath"
    Write-Info 'Отредактируйте его и выполните el-project inspect .'
}

function Invoke-RefreshProject {
    if (-not $Target) {
        throw 'Укажите проект: el-project refresh <id>'
    }
    $registry = Read-Registry
    $originalRegistry = Copy-RegistryObject -Registry $registry
    $existing = Get-Project -Registry $registry -Identity $Target
    $root = Resolve-ProjectRoot -Path $existing.root
    $manifestInfo = Read-ProjectManifest -Root $root

    $resolvedName = if ($Name) {
        $Name
    }
    elseif (
        $manifestInfo -and
        $manifestInfo.data.PSObject.Properties.Name -contains 'displayName'
    ) {
        $null
    }
    else {
        $existing.displayName
    }
    $resolvedStack = if ($Stack) {
        $Stack
    }
    elseif (
        $manifestInfo -and
        $manifestInfo.data.PSObject.Properties.Name -contains 'stack'
    ) {
        $null
    }
    else {
        $existing.stack
    }
    $resolvedIcon = if ($Icon) {
        $Icon
    }
    elseif (
        $manifestInfo -and
        $manifestInfo.data.PSObject.Properties.Name -contains 'presentation' -and
        $manifestInfo.data.presentation.PSObject.Properties.Name -contains 'icon'
    ) {
        $null
    }
    else {
        $existing.presentation.icon
    }
    $existingGitTrusted =
        $existing.PSObject.Properties.Name -contains 'gitTrusted' -and
        [bool] $existing.gitTrusted

    $definition = Resolve-ProjectDefinition `
        -Root $root `
        -Id $existing.id `
        -TerminalProfile $registry.defaults.terminalProfile `
        -RequestedName $resolvedName `
        -RequestedStack $resolvedStack `
        -RequestedIcon $resolvedIcon `
        -AssumeYes:$Yes `
        -GitTrusted:$existingGitTrusted
    $updated = $definition.project
    if (-not $updated.repository -and $existing.repository) {
        $updated.repository = $existing.repository
    }
    Assert-ProjectSnapshot `
        -Project $updated `
        -TerminalProfile $registry.defaults.terminalProfile

    Show-ProjectPreview -Project $updated
    Show-ProjectDiff -Before $existing -After $updated
    if (
        $Yes -and
        $definition.manifestInfo -and
        (
            -not $TrustManifestHash -or
            -not $TrustManifestHash.Equals(
                $definition.manifestInfo.hash,
                [StringComparison]::OrdinalIgnoreCase
            )
        )
    ) {
        throw (
            'Для неинтерактивного refresh укажите точный hash: ' +
            "-TrustManifestHash $($definition.manifestInfo.hash)"
        )
    }
    if (-not (Confirm-Action `
        -Prompt 'Обновить подтверждённый snapshot?' `
        -AssumeYes:$Yes `
        -DefaultYes)) {
        Write-Info 'Обновление отменено.'
        return
    }

    $registry.projects = @($registry.projects | ForEach-Object {
        if ($_.id.Equals($existing.id, [StringComparison]::OrdinalIgnoreCase)) {
            $updated
        }
        else {
            $_
        }
    })
    Set-RegistryUpdatedAt -Registry $registry
    Commit-RegistryChange `
        -OriginalRegistry $originalRegistry `
        -UpdatedRegistry $registry
    Write-Success "Snapshot '$($updated.displayName)' обновлён."
}

function Invoke-SetGitTrust {
    param([Parameter(Mandatory)][bool] $TrustedValue)

    if (-not $Target) {
        throw 'Укажите проект: el-project trust-git <id|path>'
    }
    $registry = Read-Registry
    $originalRegistry = Copy-RegistryObject -Registry $registry
    $project = Get-Project -Registry $registry -Identity $Target
    $root = Resolve-ProjectRoot -Path $project.root

    if ($TrustedValue) {
        if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) {
            throw "В каталоге нет Git-метаданных: $root"
        }
        if (-not (Test-GitRepository -Root $root -Trusted)) {
            throw "Git не распознал репозиторий даже в точном trusted-контексте: $root"
        }
        Write-Host
        Write-Host '  Разрешить Git только для проекта' -ForegroundColor Yellow
        Write-Info "Проект: $($project.displayName)"
        Write-Info "Путь:    $root"
        Write-Info 'Глобальный git config изменён не будет.'
        Write-Host
        if (-not (Confirm-Action `
            -Prompt 'Доверять этому пути при Git-задачах EL?' `
            -AssumeYes:$Yes)) {
            Write-Info 'Изменение отменено.'
            return
        }
        Set-ObjectProperty -Object $project -Name 'gitTrusted' -Value $true

        $main = Get-Task -Project $project -TaskId 'main'
        if (@($main.steps.runner) -notcontains 'gitStatus') {
            $main.steps = @(
                [pscustomobject][ordered]@{ runner = 'gitStatus' }
            ) + @($main.steps)
        }
        $repository = Get-RepositoryUrl -Root $root -Trusted
        if ($repository) {
            $project.repository = $repository
            if (@($project.tasks.id) -notcontains 'repository') {
                $taskList = [Collections.Generic.List[object]]::new()
                foreach ($taskItem in @($project.tasks)) {
                    $taskList.Add($taskItem)
                }
                Add-RepositoryTask `
                    -Tasks $taskList `
                    -Repository $repository `
                    -DisplayName $project.displayName `
                    -IsGit $true
                $project.tasks = @($taskList)
            }
            if (@($project.palette) -notcontains 'repository') {
                $project.palette = @($project.palette) + @('repository')
            }
        }
    }
    else {
        Write-Host
        Write-Host '  Убрать локальное Git-доверие EL' -ForegroundColor Yellow
        Write-Info "Проект: $($project.displayName)"
        Write-Info "Путь:    $root"
        Write-Host
        if (-not (Confirm-Action `
            -Prompt 'Продолжить?' `
            -AssumeYes:$Yes)) {
            Write-Info 'Изменение отменено.'
            return
        }
        Set-ObjectProperty -Object $project -Name 'gitTrusted' -Value $false
        if (-not (Test-GitRepository -Root $root)) {
            foreach ($taskItem in @($project.tasks)) {
                $taskItem.steps = @($taskItem.steps | Where-Object {
                    $_.runner -ne 'gitStatus'
                })
            }
        }
    }

    Assert-ProjectSnapshot `
        -Project $project `
        -TerminalProfile $registry.defaults.terminalProfile
    Set-RegistryUpdatedAt -Registry $registry
    Commit-RegistryChange `
        -OriginalRegistry $originalRegistry `
        -UpdatedRegistry $registry
    if ($TrustedValue) {
        Write-Success 'Git-доверие EL включено только для этого проекта.'
    }
    else {
        Write-Success 'Git-доверие EL отключено.'
    }
}

function Get-ProjectGitSummary {
    param([Parameter(Mandatory)] $Project)

    $trusted =
        $Project.PSObject.Properties.Name -contains 'gitTrusted' -and
        [bool] $Project.gitTrusted
    if (-not (Test-GitRepository -Root $Project.root -Trusted:$trusted)) {
        return $null
    }
    $arguments = [Collections.Generic.List[string]]::new()
    if ($trusted) {
        $arguments.Add('-c')
        $arguments.Add("safe.directory=$($Project.root)")
    }
    $arguments.Add('-C')
    $arguments.Add([string] $Project.root)
    $arguments.Add('status')
    $arguments.Add('--porcelain=v1')
    $arguments.Add('--branch')
    $output = @(& git.exe @arguments 2>$null)
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    $branch = ''
    if ($output.Count -gt 0) {
        if ($output[0] -match '^##\s+No commits yet on\s+(?<branch>.+)$') {
            $branch = $Matches.branch
        }
        elseif ($output[0] -match '^##\s+Initial commit on\s+(?<branch>.+)$') {
            $branch = $Matches.branch
        }
        elseif ($output[0] -match '^##\s+(?<branch>[^\s.]+)') {
            $branch = $Matches.branch
        }
    }
    return [pscustomobject]@{
        branch = $branch
        changes = [Math]::Max(0, $output.Count - 1)
        trusted = $trusted
    }
}

function Invoke-ProjectStatus {
    $registry = Read-Registry
    $projects = if ($Target) {
        @(Get-Project -Registry $registry -Identity $Target)
    }
    else {
        @($registry.projects)
    }
    $rows = foreach ($project in $projects) {
        $git = if (Test-Path -LiteralPath $project.root -PathType Container) {
            Get-ProjectGitSummary -Project $project
        }
        else {
            $null
        }
        [pscustomobject]@{
            ID = $project.id
            Project = $project.displayName
            Stack = Get-ProjectStackShortLabel -Project $project
            Git = if ($git) {
                if ($git.changes -gt 0) {
                    "$($git.branch) · $($git.changes) changes"
                }
                else {
                    "$($git.branch) · clean"
                }
            }
            elseif (Test-Path -LiteralPath (Join-Path $project.root '.git')) {
                'blocked'
            }
            else {
                '—'
            }
            Manifest = if ($project.PSObject.Properties.Name -contains 'manifest') {
                $project.manifest.sha256.Substring(0, 8)
            }
            else {
                'auto'
            }
        }
    }
    if ($Json) {
        ConvertTo-Json -InputObject @($rows) -Depth 20
        return
    }
    Write-Host
    Write-Host '  EL PROJECT STATUS' -ForegroundColor Blue
    $rows | Format-Table -AutoSize | Out-Host
}

function Invoke-Doctor {
    $failed = $false
    Write-Host
    Write-Host '  EL PROJECT MANAGER · DOCTOR' -ForegroundColor Blue
    Write-Host

    try {
        $registry = Read-Registry
        Write-Success "Реестр корректен: $script:RegistryPath"
    }
    catch {
        Write-Failure $_.Exception.Message
        return $false
    }

    foreach ($required in @(
        $script:RunnerPath,
        $script:SchemaPath,
        $script:ManifestSchemaPath
    )) {
        if (Test-Path -LiteralPath $required -PathType Leaf) {
            Write-Success "Файл найден: $(Split-Path -Leaf $required)"
        }
        else {
            Write-Failure "Файл отсутствует: $required"
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

    $terminalProfileFound = $false
    foreach ($settingsPath in @(Get-TerminalSettingsPaths)) {
        try {
            $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 |
                ConvertFrom-Json -Depth 100
            $profileGuids = @($settings.profiles.list | ForEach-Object {
                [string] $_.guid
            })
            if ($profileGuids -contains [string] $registry.defaults.terminalProfile) {
                $terminalProfileFound = $true
                break
            }
        }
        catch {
            Write-Failure "Terminal settings повреждён: $settingsPath"
            $failed = $true
        }
    }
    if ($terminalProfileFound) {
        Write-Success 'Профиль Windows Terminal найден'
    }
    else {
        Write-Failure (
            'Профиль Windows Terminal не найден: ' +
            $registry.defaults.terminalProfile
        )
        $failed = $true
    }

    $doctorProjects = if ($Target) {
        @(Get-Project -Registry $registry -Identity $Target)
    }
    else {
        @($registry.projects)
    }
    foreach ($project in $doctorProjects) {
        if (Test-Path -LiteralPath $project.root -PathType Container) {
            Write-Success "$($project.displayName): каталог доступен"
            $projectTasksReady = $true

            if ($project.PSObject.Properties.Name -contains 'requirements') {
                foreach ($requiredCommand in @($project.requirements.commands)) {
                    if (Get-Command $requiredCommand -ErrorAction SilentlyContinue) {
                        Write-Success "$($project.displayName): команда $requiredCommand доступна"
                    }
                    else {
                        Write-Failure "$($project.displayName): команда $requiredCommand не найдена"
                        $projectTasksReady = $false
                        $failed = $true
                    }
                }
            }

            if ($project.PSObject.Properties.Name -contains 'manifest') {
                $manifestPath = Join-Path $project.root $project.manifest.path
                if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
                    Write-Warning (
                        "$($project.displayName): manifest snapshot существует, " +
                        'но исходный .el-project.json отсутствует'
                    )
                }
                else {
                    $currentHash = [Convert]::ToHexString(
                        [Security.Cryptography.SHA256]::HashData(
                            [IO.File]::ReadAllBytes($manifestPath)
                        )
                    ).ToLowerInvariant()
                    if ($currentHash -eq $project.manifest.sha256) {
                        Write-Success "$($project.displayName): manifest snapshot актуален"
                    }
                    else {
                        Write-Warning (
                            "$($project.displayName): .el-project.json изменён; " +
                            'выполните el-project refresh'
                        )
                    }
                }
            }

            $containsGitTask = @($project.tasks.steps.runner) -contains 'gitStatus'
            if ($containsGitTask) {
                $gitTrusted =
                    $project.PSObject.Properties.Name -contains 'gitTrusted' -and
                    [bool] $project.gitTrusted
                if (Test-GitRepository -Root $project.root -Trusted:$gitTrusted) {
                    Write-Success "$($project.displayName): Git доступен"
                }
                else {
                    Write-Failure (
                        "$($project.displayName): Git-задача настроена, " +
                        'но репозиторий недоступен'
                    )
                    $projectTasksReady = $false
                    $failed = $true
                }
            }

            foreach ($task in @($project.tasks)) {
                try {
                    $description = & $script:RunnerPath `
                        -ProjectId $project.id `
                        -TaskId $task.id `
                        -Describe
                    [void] (($description -join [Environment]::NewLine) |
                        ConvertFrom-Json -Depth 30)
                    foreach ($step in @($task.steps)) {
                        if (
                            $step.runner -eq 'pythonModule' -and
                            $step.module -eq 'pytest'
                        ) {
                            $python = Get-Command python.exe -ErrorAction Stop
                            & $python.Source -c (
                                'import importlib.util,sys;' +
                                'sys.exit(0 if importlib.util.find_spec("pytest") else 1)'
                            )
                            if ($LASTEXITCODE -ne 0) {
                                throw 'Python-модуль pytest не установлен.'
                            }
                        }
                    }
                }
                catch {
                    Write-Failure "$($project.displayName)/$($task.id): $($_.Exception.Message)"
                    $projectTasksReady = $false
                    $failed = $true
                }
            }
            if ($projectTasksReady) {
                Write-Success "$($project.displayName): зависимости задач доступны"
            }
        }
        else {
            Write-Failure "$($project.displayName): каталог не найден — $($project.root)"
            $failed = $true
        }
    }

    $syncHealthy = Invoke-WithMutationLock {
        $latestRegistry = Read-Registry
        Sync-Projects -Registry $latestRegistry -CheckOnly
    }
    if (-not $syncHealthy) {
        $failed = $true
    }
    Write-Host
    return -not $failed
}

function Show-Help {
    Write-Host @'

  EL PROJECT MANAGER

  el-project add [path] [-Name "Имя"] [-Stack pwa] [-Icon "◫"]
      Определить стек, показать найденные задачи и добавить проект.

  el-project inspect [path] [-Json]
      Только показать, что будет добавлено. Ничего не записывает.

  el-project init [path]
      Создать безопасный шаблон .el-project.json.

  el-project refresh <id> [-TrustManifestHash <sha256>]
      Обновить подтверждённый snapshot после изменения manifest.

  el-project list [-Json]
      Показать зарегистрированные проекты.

  el-project tasks <id> [-Json]
      Показать задачи проекта.

  el-project run <id> <task> [-DryRun]
      Открыть выбранную задачу в новой вкладке Terminal.

  el-project open <id> [-Console] [-DryRun]
      Открыть workspace; -Console открывает одну консоль.

  el-project status [id] [-Json]
      Показать стек, Git и manifest проектов.

  el-project trust-git <id|path>
      Разрешить Git только для точного пути внутри EL, без global git config.

  el-project remove <id> [-Yes]
      Убрать проект из палитры. Каталог и его файлы не удаляются.

  el-project sync [-Check] [-DryRun]
      Пересобрать палитру; -Check проверяет drift, -DryRun печатает JSON.

  el-project doctor [id]
      Проверить реестр, runner, Terminal и один либо все проекты.

  Примеры:
    cd C:\Code\MyProject
    el-project init .
    el-project add .
    el-project tasks myproject
    el-project run myproject tests
    el-project open myproject
    el-project remove myproject

'@ -ForegroundColor White
}

function Assert-CommandParameters {
    param(
        [Parameter(Mandatory)][string] $CommandName,
        [Parameter(Mandatory)] $BoundParameters
    )

    $allowed = switch ($CommandName.ToLowerInvariant()) {
        'add' {
            @('Command', 'Target', 'Name', 'Stack', 'Icon', 'Yes', 'TrustManifestHash')
        }
        'init' { @('Command', 'Target', 'Name', 'Stack', 'Icon', 'Yes') }
        'refresh' {
            @('Command', 'Target', 'Name', 'Stack', 'Icon', 'Yes', 'TrustManifestHash')
        }
        'inspect' {
            @('Command', 'Target', 'Name', 'Stack', 'Icon', 'Yes', 'Json')
        }
        'list' { @('Command', 'Json') }
        'tasks' { @('Command', 'Target', 'Json') }
        'run' { @('Command', 'Target', 'Task', 'DryRun') }
        'status' { @('Command', 'Target', 'Json') }
        'open' { @('Command', 'Target', 'Console', 'DryRun') }
        'remove' { @('Command', 'Target', 'Yes') }
        'sync' { @('Command', 'Check', 'DryRun') }
        'doctor' { @('Command', 'Target') }
        'trust-git' { @('Command', 'Target', 'Yes') }
        'untrust-git' { @('Command', 'Target', 'Yes') }
        default { @('Command') }
    }
    foreach ($parameterName in @($BoundParameters.Keys)) {
        if ($parameterName -notin $allowed) {
            throw (
                "Параметр -$parameterName неприменим к команде " +
                "'$CommandName'."
            )
        }
    }
}

function Invoke-WithMutationLock {
    param([Parameter(Mandatory)][scriptblock] $Action)

    $mutex = [Threading.Mutex]::new($false, $script:RegistryMutexName)
    $acquired = $false
    $fileLock = $null
    try {
        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(15))
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
            Write-Warning 'Обнаружен прерванный процесс менеджера; состояние проверяется.'
        }
        if (-not $acquired) {
            throw 'Другой процесс сейчас обновляет реестр. Повторите команду.'
        }
        try {
            $fileLock = [IO.FileStream]::new(
                $script:RegistryLockPath,
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None
            )
        }
        catch [IO.IOException] {
            throw 'Реестр обновляется в другой Windows-сессии. Повторите команду.'
        }
        Recover-PendingTransaction
        & $Action
    }
    finally {
        if ($fileLock) {
            $fileLock.Dispose()
        }
        if ($acquired) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

try {
    if (Test-Path -LiteralPath $script:TransactionPath -PathType Leaf) {
        Invoke-WithMutationLock { }
    }
    Assert-CommandParameters `
        -CommandName $Command `
        -BoundParameters $PSBoundParameters
    switch ($Command.ToLowerInvariant()) {
        'add' {
            Invoke-WithMutationLock { Invoke-AddProject }
        }
        'init' {
            Invoke-WithMutationLock { Invoke-InitManifest }
        }
        'refresh' {
            Invoke-WithMutationLock { Invoke-RefreshProject }
        }
        'list' {
            Invoke-ListProjects
        }
        'tasks' {
            Invoke-ListTasks
        }
        'run' {
            Invoke-RunTask
        }
        'status' {
            Invoke-ProjectStatus
        }
        'open' {
            Invoke-OpenProject
        }
        'remove' {
            Invoke-WithMutationLock { Invoke-RemoveProject }
        }
        'sync' {
            if ($DryRun -and $Check) {
                throw 'Параметры -DryRun и -Check нельзя использовать одновременно.'
            }
            Invoke-WithMutationLock {
                $registry = Read-Registry
                if ($DryRun) {
                    Sync-Projects -Registry $registry -Preview
                }
                elseif ($Check) {
                    if (-not (Sync-Projects -Registry $registry -CheckOnly)) {
                        throw 'Реестр и палитра не синхронизированы.'
                    }
                }
                else {
                    [void] (Sync-Projects -Registry $registry)
                }
            }
        }
        'inspect' {
            Invoke-InspectProject
        }
        'trust-git' {
            Invoke-WithMutationLock {
                Invoke-SetGitTrust -TrustedValue $true
            }
        }
        'untrust-git' {
            Invoke-WithMutationLock {
                Invoke-SetGitTrust -TrustedValue $false
            }
        }
        'doctor' {
            if (-not (Invoke-Doctor)) {
                throw 'Doctor обнаружил ошибки.'
            }
        }
        { $_ -in @('help', '-h', '--help', '/?') } {
            Show-Help
        }
        default {
            throw "Неизвестная команда '$Command'. Выполните: el-project help"
        }
    }
    $global:LASTEXITCODE = 0
}
catch {
    Write-Host
    Write-Failure $_.Exception.Message
    Write-Host
    $global:LASTEXITCODE = 1
    return
}
