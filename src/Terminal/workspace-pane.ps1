[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,47}$')]
    [string] $ProjectId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,47}$')]
    [string] $TaskId,

    [switch] $Describe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$registryPath = Join-Path $PSScriptRoot 'projects.json'
$schemaPath = Join-Path $PSScriptRoot 'projects.schema.json'
$allowedAccents = @(
    'Black', 'DarkBlue', 'DarkGreen', 'DarkCyan', 'DarkRed', 'DarkMagenta',
    'DarkYellow', 'Gray', 'DarkGray', 'Blue', 'Green', 'Cyan', 'Red',
    'Magenta', 'Yellow', 'White'
)

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

function Resolve-InsideProject {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $RelativePath,
        [switch] $MustExist,
        [ValidateSet('Any', 'Leaf', 'Container')]
        [string] $PathType = 'Any'
    )

    if ([IO.Path]::IsPathRooted($RelativePath) -or -not (Test-SafeText $RelativePath)) {
        throw "Недопустимый относительный путь задачи: $RelativePath"
    }

    $candidate = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    $relative = [IO.Path]::GetRelativePath($Root, $candidate)
    if ($relative -eq '..' -or $relative.StartsWith(
        '..' + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::Ordinal
    )) {
        throw "Путь задачи выходит за пределы проекта: $RelativePath"
    }

    $currentPath = $Root
    $rootItem = Get-Item -LiteralPath $currentPath -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Корень проекта является reparse point: $Root"
    }
    foreach ($segment in @($relative -split '[\\/]+')) {
        if (-not $segment -or $segment -eq '.') {
            continue
        }
        $currentPath = Join-Path $currentPath $segment
        if (-not (Test-Path -LiteralPath $currentPath)) {
            break
        }
        $item = Get-Item -LiteralPath $currentPath -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Задача проходит через symlink или junction: $currentPath"
        }
    }

    if ($MustExist) {
        $exists = switch ($PathType) {
            'Leaf' { Test-Path -LiteralPath $candidate -PathType Leaf }
            'Container' { Test-Path -LiteralPath $candidate -PathType Container }
            default { Test-Path -LiteralPath $candidate }
        }
        if (-not $exists) {
            throw "Путь задачи не найден: $candidate"
        }
    }
    return $candidate
}

function Get-Arguments {
    param($Value)

    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @($Value)) {
        if ($argument -isnot [string] -or -not (Test-SafeText $argument)) {
            throw 'Аргумент задачи содержит управляющие символы или слишком длинный текст.'
        }
        $arguments.Add($argument)
    }
    return @($arguments)
}

function Get-StepWorkingDirectory {
    param(
        [Parameter(Mandatory)] $Step,
        [Parameter(Mandatory)][string] $Root
    )

    if ($Step.PSObject.Properties.Name -notcontains 'cwd') {
        return $Root
    }
    return Resolve-InsideProject -Root $Root -RelativePath $Step.cwd
}

function Get-Executable {
    param([Parameter(Mandatory)][string] $Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandType -in @('Application', 'ExternalScript') } |
        Select-Object -First 1
    if (-not $command) {
        throw "Команда не найдена: $Name"
    }
    return $command.Source
}

function Get-PythonExecutable {
    param(
        [Parameter(Mandatory)] $Project,
        [Parameter(Mandatory)][string] $WorkingDirectory
    )

    foreach ($candidate in @(
        (Join-Path $WorkingDirectory '.venv\Scripts\python.exe'),
        (Join-Path $Project.root '.venv\Scripts\python.exe')
    )) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }
        $relative = [IO.Path]::GetRelativePath($Project.root, $candidate)
        return Resolve-InsideProject `
            -Root $Project.root `
            -RelativePath $relative `
            -MustExist `
            -PathType Leaf
    }
    return Get-Executable 'python.exe'
}

function Get-Invocation {
    param(
        [Parameter(Mandatory)] $Step,
        [Parameter(Mandatory)] $Project
    )

    $workingDirectory = Get-StepWorkingDirectory -Step $Step -Root $Project.root
    $arguments = if ($Step.PSObject.Properties.Name -contains 'arguments') {
        @(Get-Arguments $Step.arguments)
    }
    else {
        @()
    }

    switch ($Step.runner) {
        'gitStatus' {
            $gitArguments = [Collections.Generic.List[string]]::new()
            if (
                $Project.PSObject.Properties.Name -contains 'gitTrusted' -and
                [bool] $Project.gitTrusted
            ) {
                $gitArguments.Add('-c')
                $gitArguments.Add("safe.directory=$($Project.root)")
            }
            $gitArguments.Add('status')
            $gitArguments.Add('--short')
            $gitArguments.Add('--branch')
            return [pscustomobject]@{
                executable = Get-Executable 'git.exe'
                arguments = @($gitArguments)
                workingDirectory = $workingDirectory
            }
        }
        'pythonModule' {
            if ($Step.module -notin @('unittest', 'pytest', 'uvicorn')) {
                throw "Недопустимый Python-модуль: $($Step.module)"
            }
            return [pscustomobject]@{
                executable = Get-PythonExecutable `
                    -Project $Project `
                    -WorkingDirectory $workingDirectory
                arguments = @('-m', [string] $Step.module) + $arguments
                workingDirectory = $workingDirectory
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
                throw "Запуск опасной package-задачи заблокирован: $($Step.script)"
            }
            $executableName = switch ($Step.manager) {
                'npm' { 'npm.cmd' }
                'pnpm' { 'pnpm.cmd' }
                'yarn' { 'yarn.cmd' }
                'bun' { 'bun.exe' }
            }
            $packagePath = Join-Path $workingDirectory 'package.json'
            if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
                throw "package.json не найден: $workingDirectory"
            }
            try {
                $package = Get-Content -LiteralPath $packagePath -Raw -Encoding UTF8 |
                    ConvertFrom-Json -Depth 30
            }
            catch {
                throw "package.json повреждён: $($_.Exception.Message)"
            }
            $scripts = if (
                $package.PSObject.Properties.Name -contains 'scripts' -and
                $package.scripts
            ) {
                @($package.scripts.PSObject.Properties.Name)
            }
            else {
                @()
            }
            if ($scripts -notcontains $Step.script) {
                throw "Package script '$($Step.script)' не найден в $packagePath."
            }
            return [pscustomobject]@{
                executable = Get-Executable $executableName
                arguments = @('run', [string] $Step.script) + $arguments
                workingDirectory = $workingDirectory
            }
        }
        'packageBinary' {
            if ($Step.name -notin @('tsc')) {
                throw "Неподдерживаемый локальный package binary: $($Step.name)"
            }
            $binary = Resolve-InsideProject `
                -Root $Project.root `
                -RelativePath "node_modules\.bin\$($Step.name).cmd" `
                -MustExist `
                -PathType Leaf
            return [pscustomobject]@{
                executable = $binary
                arguments = $arguments
                workingDirectory = $workingDirectory
            }
        }
        'powershellFile' {
            if (-not $Step.path.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'powershellFile должен указывать на .ps1.'
            }
            $scriptPath = Resolve-InsideProject `
                -Root $Project.root `
                -RelativePath $Step.path `
                -MustExist `
                -PathType Leaf
            return [pscustomobject]@{
                executable = Get-Executable 'pwsh.exe'
                arguments = @(
                    '-NoProfile',
                    '-ExecutionPolicy',
                    'Bypass',
                    '-File',
                    $scriptPath
                ) + $arguments
                workingDirectory = $workingDirectory
            }
        }
        'installedTool' {
            if ($Step.name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
                throw "Недопустимое имя установленного инструмента: $($Step.name)"
            }
            $executable = $null
            if ($Step.PSObject.Properties.Name -contains 'preferred') {
                if ($Step.preferred.base -ne 'LocalAppData' -or
                    [IO.Path]::IsPathRooted($Step.preferred.path) -or
                    -not (Test-SafeText $Step.preferred.path)) {
                    throw 'Недопустимый preferred-путь установленного инструмента.'
                }
                $localData = [Environment]::GetFolderPath(
                    [Environment+SpecialFolder]::LocalApplicationData
                )
                $preferred = [IO.Path]::GetFullPath(
                    (Join-Path $localData $Step.preferred.path)
                )
                $relative = [IO.Path]::GetRelativePath($localData, $preferred)
                if ($relative -ne '..' -and -not $relative.StartsWith(
                    '..' + [IO.Path]::DirectorySeparatorChar,
                    [StringComparison]::Ordinal
                ) -and (Test-Path -LiteralPath $preferred -PathType Leaf)) {
                    $executable = $preferred
                }
            }
            if (-not $executable) {
                $executable = Get-Executable $Step.name
            }
            return [pscustomobject]@{
                executable = $executable
                arguments = $arguments
                workingDirectory = $workingDirectory
            }
        }
        'dotnet' {
            if ($Step.verb -notin @('build', 'test', 'run')) {
                throw "Недопустимый dotnet verb: $($Step.verb)"
            }
            return [pscustomobject]@{
                executable = Get-Executable 'dotnet.exe'
                arguments = @([string] $Step.verb) + $arguments
                workingDirectory = $workingDirectory
            }
        }
        'cargo' {
            if ($Step.verb -notin @('build', 'check', 'test', 'run')) {
                throw "Недопустимый cargo verb: $($Step.verb)"
            }
            return [pscustomobject]@{
                executable = Get-Executable 'cargo.exe'
                arguments = @([string] $Step.verb) + $arguments
                workingDirectory = $workingDirectory
            }
        }
        'go' {
            if ($Step.verb -notin @('test', 'vet', 'run')) {
                throw "Недопустимый go verb: $($Step.verb)"
            }
            return [pscustomobject]@{
                executable = Get-Executable 'go.exe'
                arguments = @([string] $Step.verb) + $arguments
                workingDirectory = $workingDirectory
            }
        }
        default {
            throw "Runner '$($Step.runner)' не создаёт внешнюю команду."
        }
    }
}

function Write-WorkspaceHeader {
    param(
        [Parameter(Mandatory)] $Project,
        [Parameter(Mandatory)] $Task
    )

    $accent = if ($Project.presentation.accent -in $allowedAccents) {
        $Project.presentation.accent
    }
    else {
        'Blue'
    }
    Write-Host
    Write-Host '  ╭─ EL WORKSPACE' -ForegroundColor DarkGray
    Write-Host "  │ $($Project.displayName) / $($Task.label)" -ForegroundColor $accent
    Write-Host "  ╰─ $($Project.root)" -ForegroundColor DarkGray
    Write-Host
}

function Write-CommandResult {
    param([Parameter(Mandatory)][int] $ExitCode)

    Write-Host
    if ($ExitCode -eq 0) {
        Write-Host '  ✓ Команда выполнена успешно.' -ForegroundColor Green
    }
    else {
        Write-Host "  ✗ Команда завершилась с кодом $ExitCode." -ForegroundColor Red
    }
    Write-Host
}

function Set-TerminalTaskProgress {
    param(
        [ValidateSet(0, 1, 2, 3, 4)]
        [int] $State,
        [ValidateRange(0, 100)]
        [int] $Percent = 0
    )

    if (-not $env:WT_SESSION -or [Console]::IsOutputRedirected) {
        return
    }
    [Console]::Write("`e]9;4;$State;$Percent`a")
}

function Write-GitStatusSummary {
    param([Parameter(Mandatory)][object[]] $Output)

    $lines = @($Output | ForEach-Object { [string] $_ })
    $branchLine = @($lines | Where-Object { $_.StartsWith('## ') } | Select-Object -First 1)
    $branch = if ($branchLine.Count -eq 1) {
        $branchLine[0].Substring(3)
    }
    else {
        'ветка не определена'
    }
    $changes = @($lines | Where-Object { -not $_.StartsWith('## ') -and $_ })

    Write-Host "  Git · $branch" -ForegroundColor DarkGray
    if ($changes.Count -eq 0) {
        Write-Host '  ✓ Рабочее дерево чистое.' -ForegroundColor Green
        return
    }

    $modified = @($changes | Where-Object {
        $_.Length -ge 2 -and $_.Substring(0, 2) -match 'M'
    }).Count
    $added = @($changes | Where-Object {
        $_.Length -ge 2 -and $_.Substring(0, 2) -match 'A'
    }).Count
    $deleted = @($changes | Where-Object {
        $_.Length -ge 2 -and $_.Substring(0, 2) -match 'D'
    }).Count
    $renamed = @($changes | Where-Object {
        $_.Length -ge 2 -and $_.Substring(0, 2) -match 'R'
    }).Count
    $untracked = @($changes | Where-Object { $_.StartsWith('??') }).Count

    $parts = [Collections.Generic.List[string]]::new()
    if ($modified) { $parts.Add("M $modified") }
    if ($added) { $parts.Add("A $added") }
    if ($deleted) { $parts.Add("D $deleted") }
    if ($renamed) { $parts.Add("R $renamed") }
    if ($untracked) { $parts.Add("? $untracked") }
    $details = if ($parts.Count -gt 0) { ' · ' + ($parts -join ' · ') } else { '' }
    Write-Host "  Изменения: $($changes.Count)$details" -ForegroundColor Yellow
    Write-Host '  Полный список: git status --short' -ForegroundColor DarkGray
}

function Invoke-StructuredStep {
    param(
        [Parameter(Mandatory)] $Step,
        [Parameter(Mandatory)] $Project,
        [switch] $DescribeOnly
    )

    if ($Step.runner -eq 'workspaceShell') {
        $workingDirectory = Get-StepWorkingDirectory -Step $Step -Root $Project.root
        if ($DescribeOnly) {
            return [pscustomobject]@{
                runner = 'workspaceShell'
                workingDirectory = $workingDirectory
            }
        }
        Set-Location -LiteralPath $workingDirectory
        $relative = [IO.Path]::GetRelativePath($Project.root, $workingDirectory)
        Write-Host "  Консоль готова: $relative" -ForegroundColor DarkGray
        return 0
    }

    if ($Step.runner -eq 'message') {
        if (-not (Test-SafeText -Value $Step.text -MaximumLength 1024)) {
            throw 'Сообщение задачи содержит недопустимый текст.'
        }
        if ($DescribeOnly) {
            return [pscustomobject]@{
                runner = 'message'
                text = $Step.text
            }
        }
        Write-Host "  $($Step.text)" -ForegroundColor DarkGray
        return 0
    }

    if ($Step.runner -eq 'openRepository') {
        $repositoryUri = $null
        if (-not $Project.repository -or -not [Uri]::TryCreate(
            $Project.repository,
            [UriKind]::Absolute,
            [ref] $repositoryUri
        ) -or
            $repositoryUri.Scheme -ne 'https' -or
            $repositoryUri.UserInfo -or
            $repositoryUri.Query -or
            $repositoryUri.Fragment) {
            throw 'У проекта нет безопасного HTTPS URL репозитория.'
        }
        if ($DescribeOnly) {
            return [pscustomobject]@{
                runner = 'openRepository'
                url = $repositoryUri.AbsoluteUri
            }
        }
        Start-Process -FilePath $repositoryUri.AbsoluteUri
        Write-Host "  Открыт $($repositoryUri.AbsoluteUri)" -ForegroundColor DarkGray
        return 0
    }

    $invocation = Get-Invocation -Step $Step -Project $Project
    if ($DescribeOnly) {
        return [pscustomobject]@{
            runner = $Step.runner
            executable = $invocation.executable
            arguments = @($invocation.arguments)
            workingDirectory = $invocation.workingDirectory
        }
    }

    Push-Location -LiteralPath $invocation.workingDirectory
    try {
        $global:LASTEXITCODE = 0
        if ($Step.runner -eq 'gitStatus') {
            $output = @(& $invocation.executable @($invocation.arguments) 2>&1)
        }
        else {
            & $invocation.executable @($invocation.arguments) | Out-Host
        }
        $exitCode = $global:LASTEXITCODE
        if ($null -eq $exitCode) {
            $exitCode = 0
        }
        if ($Step.runner -eq 'gitStatus' -and $exitCode -eq 0) {
            Write-GitStatusSummary -Output $output
            return 0
        }
        if ($Step.runner -eq 'gitStatus') {
            $output | Out-Host
        }
        Write-CommandResult -ExitCode $exitCode
        return $exitCode
    }
    finally {
        Pop-Location
    }
}

if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
    throw "Реестр проектов не найден: $registryPath"
}

try {
    $registryJson = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8
    $document = [Text.Json.JsonDocument]::Parse([string] $registryJson)
    try {
        Assert-NoDuplicateJsonProperties -Element $document.RootElement
    }
    finally {
        $document.Dispose()
    }
    if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
        throw "Схема реестра не найдена: $schemaPath"
    }
    $schemaJson = Get-Content -LiteralPath $schemaPath -Raw -Encoding UTF8
    if (-not ($registryJson | Test-Json -Schema $schemaJson -ErrorAction SilentlyContinue)) {
        throw 'Реестр проектов не соответствует projects.schema.json.'
    }
    $registry = $registryJson | ConvertFrom-Json -Depth 100
}
catch {
    throw "Реестр проектов повреждён: $($_.Exception.Message)"
}

if ($registry.schemaVersion -ne 1) {
    throw "Неподдерживаемая версия реестра: $($registry.schemaVersion)"
}

$projects = @($registry.projects | Where-Object {
    $_.id.Equals($ProjectId, [StringComparison]::OrdinalIgnoreCase)
})
if ($projects.Count -ne 1) {
    throw "Проект '$ProjectId' не найден."
}
$project = $projects[0]

if (-not $project.trusted) {
    throw "Проект '$ProjectId' не подтверждён как trusted."
}
if (-not (Test-Path -LiteralPath $project.root -PathType Container)) {
    throw "Каталог проекта не найден: $($project.root)"
}
$resolvedRoot = (Resolve-Path -LiteralPath $project.root).ProviderPath
if (-not [IO.Path]::IsPathFullyQualified($resolvedRoot)) {
    throw "Корень проекта должен быть абсолютным: $resolvedRoot"
}
$project.root = [IO.Path]::GetFullPath($resolvedRoot).TrimEnd('\', '/')

$tasks = @($project.tasks | Where-Object {
    $_.id.Equals($TaskId, [StringComparison]::OrdinalIgnoreCase)
})
if ($tasks.Count -ne 1) {
    throw "Задача '$TaskId' не найдена в проекте '$ProjectId'."
}
$task = $tasks[0]
$env:EL_PROJECT_ID = [string] $project.id
$env:EL_PROJECT_LABEL = [string] $project.displayName
$env:EL_PROJECT_STACK = [string] $project.stack
$env:EL_TASK_ID = [string] $task.id
$env:EL_TASK_LABEL = [string] $task.label

$previousEnvironment = @{}
if ($task.PSObject.Properties.Name -contains 'environment') {
    foreach ($property in $task.environment.PSObject.Properties) {
        if ($property.Name -notmatch '^[A-Z][A-Z0-9_]{0,63}$' -or
            -not (Test-SafeText -Value ([string] $property.Value))) {
            throw "Недопустимая переменная окружения задачи: $($property.Name)"
        }
    }
}

if (-not (Test-SafeText -Value $project.displayName -MaximumLength 80) -or
    -not (Test-SafeText -Value $task.label -MaximumLength 100) -or
    -not (Test-SafeText -Value $task.tabTitle -MaximumLength 100)) {
    throw 'Название проекта или задачи содержит недопустимый текст.'
}

$preflight = foreach ($step in @($task.steps)) {
    Invoke-StructuredStep -Step $step -Project $project -DescribeOnly
}

if ($Describe) {
    [pscustomobject]@{
        projectId = $project.id
        taskId = $task.id
        root = $project.root
        steps = @($preflight)
    } | ConvertTo-Json -Depth 30
    return
}

$Host.UI.RawUI.WindowTitle = "EL · $($project.displayName) · $($task.label)"
Write-WorkspaceHeader -Project $project -Task $task

if ($task.PSObject.Properties.Name -contains 'environment') {
    foreach ($property in $task.environment.PSObject.Properties) {
        $previousEnvironment[$property.Name] = [Environment]::GetEnvironmentVariable(
            $property.Name,
            [EnvironmentVariableTarget]::Process
        )
        [Environment]::SetEnvironmentVariable(
            $property.Name,
            [string] $property.Value,
            [EnvironmentVariableTarget]::Process
        )
    }
}

try {
    Set-Location -LiteralPath $project.root
    $showProgress = @($task.steps | Where-Object {
        $_.runner -notin @(
            'message',
            'workspaceShell',
            'gitStatus',
            'openRepository'
        )
    }).Count -gt 0
    if ($showProgress) {
        Set-TerminalTaskProgress -State 3
    }
    foreach ($step in @($task.steps)) {
        $exitCode = Invoke-StructuredStep -Step $step -Project $project
        $continueOnError = $step.PSObject.Properties.Name -contains 'continueOnError' -and
            [bool] $step.continueOnError
        if ($exitCode -ne 0 -and -not $continueOnError) {
            break
        }
    }
}
finally {
    Set-TerminalTaskProgress -State 0
    foreach ($name in @($previousEnvironment.Keys)) {
        [Environment]::SetEnvironmentVariable(
            $name,
            $previousEnvironment[$name],
            [EnvironmentVariableTarget]::Process
        )
    }
}
