Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ToolRoot = $PSScriptRoot
$script:ManagerPath = Join-Path $script:ToolRoot 'el-project.ps1'
$script:RegistryPath = Join-Path $script:ToolRoot 'projects.json'
$script:StatePath = Join-Path $script:ToolRoot 'launcher-state.json'
$script:StateLockPath = Join-Path $script:ToolRoot '.launcher-state.lock'
$script:BackupRoot = Join-Path $script:ToolRoot 'backups'
$script:StateMutexName = 'Local\EL.ProjectLauncher.State'
$script:Esc = [char] 27
$script:LastManagerExitCode = 0
$global:LASTEXITCODE = 0

function Test-SafeDisplayText {
    param(
        [AllowNull()][string] $Value,
        [int] $MaximumLength = 100
    )

    return (
        $null -ne $Value -and
        $Value.Length -le $MaximumLength -and
        $Value -notmatch '[\x00-\x1F\x7F-\x9F]'
    )
}

function Read-LauncherRegistry {
    if (-not (Test-Path -LiteralPath $script:RegistryPath -PathType Leaf)) {
        throw "Реестр проектов не найден: $script:RegistryPath"
    }
    try {
        $registry = Get-Content `
            -LiteralPath $script:RegistryPath `
            -Raw `
            -Encoding UTF8 | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "Реестр проектов повреждён: $($_.Exception.Message)"
    }
    if ($registry.schemaVersion -ne 1) {
        throw "Неподдерживаемая версия реестра: $($registry.schemaVersion)"
    }
    foreach ($project in @($registry.projects)) {
        if (
            $project.id -notmatch '^[a-z0-9][a-z0-9-]{0,47}$' -or
            -not (Test-SafeDisplayText -Value $project.displayName -MaximumLength 80) -or
            -not (Test-SafeDisplayText -Value $project.presentation.icon -MaximumLength 8)
        ) {
            throw "Небезопасные данные интерфейса у проекта '$($project.id)'."
        }
        foreach ($task in @($project.tasks)) {
            if (
                $task.id -notmatch '^[a-z0-9][a-z0-9-]{0,47}$' -or
                -not (Test-SafeDisplayText -Value $task.label) -or
                -not (Test-SafeDisplayText -Value $task.icon -MaximumLength 8)
            ) {
                throw "Небезопасные данные интерфейса у задачи '$($project.id)/$($task.id)'."
            }
        }
    }
    return $registry
}

function New-LauncherState {
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        updatedAt = [DateTime]::UtcNow.ToString('o')
        favorites = @()
        recent = @()
    }
}

function Read-LauncherState {
    if (-not (Test-Path -LiteralPath $script:StatePath -PathType Leaf)) {
        return New-LauncherState
    }
    try {
        $state = Get-Content `
            -LiteralPath $script:StatePath `
            -Raw `
            -Encoding UTF8 | ConvertFrom-Json -Depth 30
    }
    catch {
        Write-Warning "Состояние launcher повреждено и будет пересоздано: $($_.Exception.Message)"
        return New-LauncherState
    }
    if ($state.schemaVersion -ne 1) {
        Write-Warning 'Версия состояния launcher неизвестна; используется чистое состояние.'
        return New-LauncherState
    }

    $favorites = [Collections.Generic.List[string]]::new()
    $seenFavorites = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $rawFavorites = if ($state.PSObject.Properties.Name -contains 'favorites') {
        @($state.favorites)
    }
    else {
        @()
    }
    foreach ($id in $rawFavorites) {
        if (
            "$id" -match '^[a-z0-9][a-z0-9-]{0,47}$' -and
            $seenFavorites.Add([string] $id)
        ) {
            $favorites.Add([string] $id)
        }
    }
    $recent = [Collections.Generic.List[object]]::new()
    $seenRecent = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $rawRecent = if ($state.PSObject.Properties.Name -contains 'recent') {
        @($state.recent)
    }
    else {
        @()
    }
    foreach ($entry in $rawRecent) {
        $parsed = [DateTimeOffset]::MinValue
        if (
            $entry.PSObject.Properties.Name -contains 'projectId' -and
            $entry.PSObject.Properties.Name -contains 'lastOpenedAt' -and
            "$($entry.projectId)" -match '^[a-z0-9][a-z0-9-]{0,47}$' -and
            [DateTimeOffset]::TryParse([string] $entry.lastOpenedAt, [ref] $parsed) -and
            $seenRecent.Add([string] $entry.projectId)
        ) {
            $recent.Add([pscustomobject][ordered]@{
                projectId = [string] $entry.projectId
                lastOpenedAt = $parsed.ToUniversalTime().ToString('o')
                openCount = if (
                    $entry.PSObject.Properties.Name -contains 'openCount'
                ) {
                    [Math]::Max(1, [int] $entry.openCount)
                }
                else {
                    1
                }
            })
        }
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        updatedAt = [DateTime]::UtcNow.ToString('o')
        favorites = @($favorites)
        recent = @($recent | Sort-Object lastOpenedAt -Descending | Select-Object -First 20)
    }
}

function Write-LauncherState {
    param([Parameter(Mandatory)] $State)

    $State.updatedAt = [DateTime]::UtcNow.ToString('o')
    $content = ($State | ConvertTo-Json -Depth 30) + [Environment]::NewLine
    [void] ($content | ConvertFrom-Json -Depth 30)
    [IO.Directory]::CreateDirectory($script:ToolRoot) | Out-Null
    [IO.Directory]::CreateDirectory($script:BackupRoot) | Out-Null
    $temporary = Join-Path $script:ToolRoot (
        '.launcher-state.{0}.{1}.tmp' -f $PID, [Guid]::NewGuid().ToString('N')
    )
    $utf8 = [Text.UTF8Encoding]::new($false)
    try {
        [IO.File]::WriteAllText($temporary, $content, $utf8)
        [void] ([IO.File]::ReadAllText($temporary, $utf8) |
            ConvertFrom-Json -Depth 30)
        if (Test-Path -LiteralPath $script:StatePath -PathType Leaf) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
            $nonce = [Guid]::NewGuid().ToString('N').Substring(0, 8)
            $backup = Join-Path $script:BackupRoot (
                "launcher-state-$stamp-$nonce.json"
            )
            [IO.File]::Replace($temporary, $script:StatePath, $backup, $true)
        }
        else {
            [IO.File]::Move($temporary, $script:StatePath)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Invoke-StateMutation {
    param([Parameter(Mandatory)][scriptblock] $Action)

    $mutex = [Threading.Mutex]::new($false, $script:StateMutexName)
    $acquired = $false
    $fileLock = $null
    try {
        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(5))
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw 'Launcher state сейчас обновляется другим процессом.'
        }
        try {
            $fileLock = [IO.FileStream]::new(
                $script:StateLockPath,
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None
            )
        }
        catch [IO.IOException] {
            throw 'Launcher state обновляется в другой Windows-сессии.'
        }
        $state = Read-LauncherState
        & $Action $state
        Write-LauncherState -State $state
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

function Set-Favorite {
    param(
        [Parameter(Mandatory)][string] $ProjectId,
        [Parameter(Mandatory)][bool] $Favorite
    )

    Invoke-StateMutation {
        param($state)
        $current = @($state.favorites | Where-Object {
            -not "$_".Equals($ProjectId, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($Favorite) {
            $state.favorites = @($current) + @($ProjectId)
        }
        else {
            $state.favorites = @($current)
        }
    }
}

function Add-RecentProject {
    param([Parameter(Mandatory)][string] $ProjectId)

    try {
        Invoke-StateMutation {
            param($state)
            $existing = @($state.recent | Where-Object {
                "$($_.projectId)".Equals(
                    $ProjectId,
                    [StringComparison]::OrdinalIgnoreCase
                )
            } | Select-Object -First 1)
            $openCount = if ($existing.Count -eq 1) {
                [int] $existing[0].openCount + 1
            }
            else {
                1
            }
            $entry = [pscustomobject][ordered]@{
                projectId = $ProjectId
                lastOpenedAt = [DateTime]::UtcNow.ToString('o')
                openCount = $openCount
            }
            $state.recent = @($entry) + @(
                $state.recent | Where-Object {
                    -not "$($_.projectId)".Equals(
                        $ProjectId,
                        [StringComparison]::OrdinalIgnoreCase
                    )
                } | Select-Object -First 19
            )
        }
    }
    catch {
        Write-Warning "Проект открыт, но recent не обновлён: $($_.Exception.Message)"
    }
}

function Test-InteractiveConsole {
    if (
        [Console]::IsInputRedirected -or
        [Console]::IsOutputRedirected -or
        -not [Environment]::UserInteractive
    ) {
        return $false
    }
    if ($env:WT_SESSION) {
        return $true
    }
    return (
        $Host.UI.PSObject.Properties.Name -contains 'SupportsVirtualTerminal' -and
        $Host.UI.SupportsVirtualTerminal
    )
}

function Get-StackShortName {
    param([Parameter(Mandatory)][string] $Stack)

    switch ($Stack) {
        'compose' { 'Docker Compose' }
        'pwa' { 'Full-stack PWA' }
        'node' { 'Node.js' }
        'python' { 'Python' }
        'dotnet' { '.NET' }
        'rust' { 'Rust' }
        'go' { 'Go' }
        default { 'Generic' }
    }
}

function Get-RelativeTime {
    param([AllowNull()][string] $Value)

    if (-not $Value) {
        return ''
    }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Value, [ref] $parsed)) {
        return ''
    }
    $elapsed = [DateTimeOffset]::UtcNow - $parsed.ToUniversalTime()
    if ($elapsed.TotalMinutes -lt 1) { return 'сейчас' }
    if ($elapsed.TotalHours -lt 1) { return "$([int] $elapsed.TotalMinutes) мин" }
    if ($elapsed.TotalDays -lt 1) { return "$([int] $elapsed.TotalHours) ч" }
    return "$([int] $elapsed.TotalDays) д"
}

function Get-LauncherProjects {
    param(
        [Parameter(Mandatory)] $Registry,
        [Parameter(Mandatory)] $State,
        [ValidateSet('all', 'recent', 'favorites')]
        [string] $Mode = 'all',
        [string] $Query = ''
    )

    $favoriteSet = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($favoriteId in @($State.favorites)) {
        [void] $favoriteSet.Add([string] $favoriteId)
    }
    $recentMap = @{}
    foreach ($entry in @($State.recent)) {
        $recentMap[[string] $entry.projectId] = $entry
    }
    $items = foreach ($project in @($Registry.projects)) {
        $isFavorite = $favoriteSet.Contains([string] $project.id)
        $recentEntry = if ($recentMap.ContainsKey([string] $project.id)) {
            $recentMap[[string] $project.id]
        }
        else {
            $null
        }
        if ($Mode -eq 'favorites' -and -not $isFavorite) {
            continue
        }
        if ($Mode -eq 'recent' -and -not $recentEntry) {
            continue
        }
        if (
            $Query -and
            $project.id -notlike "*$Query*" -and
            $project.displayName -notlike "*$Query*"
        ) {
            continue
        }
        [pscustomobject]@{
            project = $project
            favorite = $isFavorite
            lastOpenedAt = if ($recentEntry) { $recentEntry.lastOpenedAt } else { '' }
            recentTicks = if ($recentEntry) {
                ([DateTimeOffset]::Parse($recentEntry.lastOpenedAt)).UtcDateTime.Ticks
            }
            else {
                0L
            }
        }
    }
    return @($items | Sort-Object `
        @{ Expression = { -not $_.favorite }; Ascending = $true },
        @{ Expression = { $_.recentTicks }; Descending = $true },
        @{ Expression = { $_.project.displayName }; Ascending = $true })
}

function Write-LauncherFrame {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Items,
        [Parameter(Mandatory)][int] $Selected,
        [string] $Query,
        [string] $Mode
    )

    Write-Host "$($script:Esc)[H$($script:Esc)[2J" -NoNewline
    Write-Host '  EL WORKSPACE' -ForegroundColor Blue
    Write-Host '  ─────────────────────────────────────────────────────────────' `
        -ForegroundColor DarkGray
    if ($Mode -ne 'all') {
        Write-Host "  Режим: $Mode" -ForegroundColor DarkGray
    }
    if ($Query) {
        Write-Host "  Поиск: $Query" -ForegroundColor Cyan
    }
    Write-Host

    if ($Items.Count -eq 0) {
        Write-Host '  Ничего не найдено.' -ForegroundColor Yellow
    }
    else {
        $windowHeight = try { [Console]::WindowHeight } catch { 24 }
        $pageSize = [Math]::Max(5, [Math]::Min(15, $windowHeight - 10))
        $pageStart = [Math]::Floor($Selected / $pageSize) * $pageSize
        $pageEnd = [Math]::Min($Items.Count - 1, $pageStart + $pageSize - 1)
        for ($index = $pageStart; $index -le $pageEnd; $index++) {
            $item = $Items[$index]
            $project = $item.project
            $pointer = if ($index -eq $Selected) { '›' } else { ' ' }
            $star = if ($item.favorite) { '★' } else { ' ' }
            $availability = if (
                Test-Path -LiteralPath $project.root -PathType Container
            ) {
                Get-RelativeTime -Value $item.lastOpenedAt
            }
            else {
                'путь недоступен'
            }
            $line = '  {0} {1} {2}  {3,-22}  {4,-16}  {5}' -f (
                $pointer,
                $star,
                $project.presentation.icon,
                $project.displayName,
                (Get-StackShortName -Stack $project.stack),
                $availability
            )
            if ($index -eq $Selected) {
                Write-Host "$($script:Esc)[7m$line$($script:Esc)[0m"
            }
            elseif (-not (Test-Path -LiteralPath $project.root -PathType Container)) {
                Write-Host $line -ForegroundColor DarkRed
            }
            else {
                Write-Host $line
            }
        }
    }
    Write-Host
    Write-Host '  ↑↓ выбор   Enter workspace   T задачи   C консоль' `
        -ForegroundColor DarkGray
    Write-Host '  G GitHub   D doctor   Space избранное   Esc выход' `
        -ForegroundColor DarkGray
    Write-Host '  Поиск: печатайте название, Backspace удаляет символ' `
        -ForegroundColor DarkGray
}

function Select-LauncherProject {
    param(
        [Parameter(Mandatory)] $Registry,
        [ValidateSet('all', 'recent', 'favorites')]
        [string] $Mode = 'all'
    )

    if (-not (Test-InteractiveConsole)) {
        $state = Read-LauncherState
        $items = @(Get-LauncherProjects `
            -Registry $Registry `
            -State $state `
            -Mode $Mode)
        Write-Host
        Write-Host '  EL WORKSPACE' -ForegroundColor Blue
        foreach ($item in $items) {
            Write-Host (
                "  $($item.project.presentation.icon) " +
                "$($item.project.id) · $($item.project.displayName) · " +
                (Get-StackShortName -Stack $item.project.stack)
            )
        }
        Write-Host
        Write-Host '  Использование: el <project> | el run <project> [task]' `
            -ForegroundColor DarkGray
        return $null
    }

    $previousCursor = [Console]::CursorVisible
    $query = ''
    $selected = 0
    Write-Host "$($script:Esc)[?1049h" -NoNewline
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            $state = Read-LauncherState
            $items = @(Get-LauncherProjects `
                -Registry $Registry `
                -State $state `
                -Mode $Mode `
                -Query $query)
            if ($items.Count -eq 0) {
                $selected = 0
            }
            else {
                $selected = [Math]::Max(0, [Math]::Min($selected, $items.Count - 1))
            }
            Write-LauncherFrame `
                -Items $items `
                -Selected $selected `
                -Query $query `
                -Mode $Mode
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow' {
                    if ($items.Count -gt 0) {
                        $selected = ($selected - 1 + $items.Count) % $items.Count
                    }
                }
                'DownArrow' {
                    if ($items.Count -gt 0) {
                        $selected = ($selected + 1) % $items.Count
                    }
                }
                'Enter' {
                    if ($items.Count -gt 0) {
                        return [pscustomobject]@{
                            action = 'workspace'
                            project = $items[$selected].project
                        }
                    }
                }
                'RightArrow' {
                    if ($items.Count -gt 0) {
                        return [pscustomobject]@{
                            action = 'tasks'
                            project = $items[$selected].project
                        }
                    }
                }
                'T' {
                    if ($items.Count -gt 0) {
                        return [pscustomobject]@{
                            action = 'tasks'
                            project = $items[$selected].project
                        }
                    }
                }
                'C' {
                    if ($items.Count -gt 0) {
                        return [pscustomobject]@{
                            action = 'console'
                            project = $items[$selected].project
                        }
                    }
                }
                'G' {
                    if (
                        $items.Count -gt 0 -and
                        $items[$selected].project.repository
                    ) {
                        return [pscustomobject]@{
                            action = 'repository'
                            project = $items[$selected].project
                        }
                    }
                }
                'D' {
                    if ($items.Count -gt 0) {
                        return [pscustomobject]@{
                            action = 'doctor'
                            project = $items[$selected].project
                        }
                    }
                }
                'Spacebar' {
                    if ($items.Count -gt 0) {
                        Set-Favorite `
                            -ProjectId $items[$selected].project.id `
                            -Favorite (-not $items[$selected].favorite)
                    }
                }
                'Backspace' {
                    if ($query.Length -gt 0) {
                        $query = $query.Substring(0, $query.Length - 1)
                        $selected = 0
                    }
                }
                'Escape' { return $null }
                default {
                    if (
                        -not [char]::IsControl($key.KeyChar) -and
                        [char]::IsLetterOrDigit($key.KeyChar)
                    ) {
                        $query += $key.KeyChar
                        $selected = 0
                    }
                }
            }
        }
    }
    finally {
        [Console]::CursorVisible = $previousCursor
        Write-Host "$($script:Esc)[?1049l" -NoNewline
    }
}

function Select-ProjectTask {
    param([Parameter(Mandatory)] $Project)

    $ordered = [Collections.Generic.List[object]]::new()
    $ordered.Add([pscustomobject]@{
        id = '__workspace'
        label = 'Открыть workspace'
        icon = '▦'
    })
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($id in @('main') + @($Project.palette) + @($Project.tasks.id)) {
        if (-not $seen.Add([string] $id)) {
            continue
        }
        $match = @($Project.tasks | Where-Object {
            $_.id.Equals([string] $id, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($match.Count -eq 1) {
            $ordered.Add($match[0])
        }
    }

    if (-not (Test-InteractiveConsole)) {
        Write-Host
        foreach ($task in @($ordered)) {
            Write-Host "  $($task.icon) $($task.id) · $($task.label)"
        }
        return $null
    }
    $selected = 0
    $previousCursor = [Console]::CursorVisible
    Write-Host "$($script:Esc)[?1049h" -NoNewline
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            Write-Host "$($script:Esc)[H$($script:Esc)[2J" -NoNewline
            Write-Host "  $($Project.presentation.icon) $($Project.displayName) · TASKS" `
                -ForegroundColor Cyan
            Write-Host
            for ($index = 0; $index -lt $ordered.Count; $index++) {
                $task = $ordered[$index]
                $line = "  $(if ($index -eq $selected) { '›' } else { ' ' }) " +
                    "$($task.icon) $($task.label)"
                if ($index -eq $selected) {
                    Write-Host "$($script:Esc)[7m$line$($script:Esc)[0m"
                }
                else {
                    Write-Host $line
                }
            }
            Write-Host
            Write-Host '  ↑↓ выбор   Enter запустить   Esc назад' `
                -ForegroundColor DarkGray
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow' {
                    $selected = ($selected - 1 + $ordered.Count) % $ordered.Count
                }
                'DownArrow' {
                    $selected = ($selected + 1) % $ordered.Count
                }
                'Enter' { return $ordered[$selected] }
                'Escape' { return $null }
            }
        }
    }
    finally {
        [Console]::CursorVisible = $previousCursor
        Write-Host "$($script:Esc)[?1049l" -NoNewline
    }
}

function Invoke-Manager {
    param([Parameter(Mandatory)][object[]] $Arguments)

    if (-not (Test-Path -LiteralPath $script:ManagerPath -PathType Leaf)) {
        throw "Менеджер не найден: $script:ManagerPath"
    }
    & $script:ManagerPath @Arguments
    $script:LastManagerExitCode = [int] $global:LASTEXITCODE
}

function Resolve-LauncherProject {
    param(
        [Parameter(Mandatory)] $Registry,
        [Parameter(Mandatory)][string] $Identity
    )

    $matches = @($Registry.projects | Where-Object {
        $_.id.Equals($Identity, [StringComparison]::OrdinalIgnoreCase) -or
        $_.displayName.Equals($Identity, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($matches.Count -eq 1) {
        return $matches[0]
    }
    if (Test-Path -LiteralPath $Identity -PathType Container) {
        $resolved = [IO.Path]::GetFullPath(
            (Resolve-Path -LiteralPath $Identity).ProviderPath
        ).TrimEnd('\', '/')
        $matches = @($Registry.projects | Where-Object {
            [IO.Path]::GetFullPath($_.root).TrimEnd('\', '/').Equals(
                $resolved,
                [StringComparison]::OrdinalIgnoreCase
            )
        })
        if ($matches.Count -eq 1) {
            return $matches[0]
        }
    }
    throw "Проект '$Identity' не найден."
}

function Invoke-OpenAndRemember {
    param(
        [Parameter(Mandatory)][string] $ProjectId,
        [switch] $Console
    )

    $registry = Read-LauncherRegistry
    $project = Resolve-LauncherProject `
        -Registry $registry `
        -Identity $ProjectId
    $managerArguments = @('open', $project.id)
    if ($Console) {
        $managerArguments += '-Console'
    }
    Invoke-Manager -Arguments $managerArguments
    $code = $script:LastManagerExitCode
    if ($code -eq 0) {
        Add-RecentProject -ProjectId $project.id
    }
    return $code
}

function Invoke-LauncherDashboard {
    param(
        [ValidateSet('all', 'recent', 'favorites')]
        [string] $Mode = 'all'
    )

    $registry = Read-LauncherRegistry
    while ($true) {
        $selection = Select-LauncherProject -Registry $registry -Mode $Mode
        if (-not $selection) {
            return
        }
        if ($selection.action -eq 'workspace') {
            [void] (Invoke-OpenAndRemember -ProjectId $selection.project.id)
            return
        }
        if ($selection.action -eq 'console') {
            [void] (Invoke-OpenAndRemember `
                -ProjectId $selection.project.id `
                -Console)
            return
        }
        if ($selection.action -eq 'tasks') {
            $task = Select-ProjectTask -Project $selection.project
            if (-not $task) {
                continue
            }
            if ($task.id -eq '__workspace') {
                [void] (Invoke-OpenAndRemember -ProjectId $selection.project.id)
            }
            else {
                Invoke-Manager -Arguments @(
                    'run',
                    $selection.project.id,
                    $task.id
                )
                $code = $script:LastManagerExitCode
                if ($code -eq 0) {
                    Add-RecentProject -ProjectId $selection.project.id
                }
            }
            return
        }
        if ($selection.action -eq 'doctor') {
            Invoke-Manager -Arguments @('doctor', $selection.project.id)
            return
        }
        if ($selection.action -eq 'repository') {
            $repositoryUri = $null
            if (
                -not [Uri]::TryCreate(
                    [string] $selection.project.repository,
                    [UriKind]::Absolute,
                    [ref] $repositoryUri
                ) -or
                $repositoryUri.Scheme -ne 'https' -or
                $repositoryUri.UserInfo -or
                $repositoryUri.Query -or
                $repositoryUri.Fragment
            ) {
                throw 'У проекта нет безопасного HTTPS URL репозитория.'
            }
            Start-Process -FilePath $repositoryUri.AbsoluteUri
            return
        }
    }
}

function Show-ElHelp {
    Write-Host @'

  EL WORKSPACE LAUNCHER

  el                         Интерактивный выбор проекта
  el <project>               Открыть workspace
  el run <project> [task]    Выбрать или запустить задачу
  el recent                  Недавние проекты
  el favorites               Избранные проекты
  el pin <project>           Добавить в избранное
  el unpin <project>         Убрать из избранного
  el last                    Открыть последний проект
  el status [project]        Краткий статус
  el help                    Эта справка

  Все команды el-project также доступны через el.

'@ -ForegroundColor White
}

try {
    $inputArguments = @($args)
    if ($inputArguments.Count -eq 0) {
        Invoke-LauncherDashboard
        $global:LASTEXITCODE = 0
        return
    }

    $command = ([string] $inputArguments[0]).ToLowerInvariant()
    switch ($command) {
        'help' {
            Show-ElHelp
        }
        { $_ -in @('-h', '--help', '/?') } {
            Show-ElHelp
        }
        'recent' {
            Invoke-LauncherDashboard -Mode recent
        }
        { $_ -in @('favorite', 'favorites', 'pinned') } {
            Invoke-LauncherDashboard -Mode favorites
        }
        'pin' {
            if ($inputArguments.Count -lt 2) {
                throw 'Использование: el pin <project>'
            }
            $registry = Read-LauncherRegistry
            $identity = [string] $inputArguments[1]
            $project = @($registry.projects | Where-Object {
                $_.id.Equals($identity, [StringComparison]::OrdinalIgnoreCase) -or
                $_.displayName.Equals($identity, [StringComparison]::OrdinalIgnoreCase)
            })
            if ($project.Count -ne 1) {
                throw "Проект '$identity' не найден."
            }
            Set-Favorite -ProjectId $project[0].id -Favorite $true
            Write-Host "  ★ $($project[0].displayName) добавлен в избранное." `
                -ForegroundColor Green
        }
        'unpin' {
            if ($inputArguments.Count -lt 2) {
                throw 'Использование: el unpin <project>'
            }
            $registry = Read-LauncherRegistry
            $identity = [string] $inputArguments[1]
            $project = @($registry.projects | Where-Object {
                $_.id.Equals($identity, [StringComparison]::OrdinalIgnoreCase) -or
                $_.displayName.Equals($identity, [StringComparison]::OrdinalIgnoreCase)
            })
            if ($project.Count -ne 1) {
                throw "Проект '$identity' не найден."
            }
            Set-Favorite -ProjectId $project[0].id -Favorite $false
            Write-Host "  $($project[0].displayName) убран из избранного." `
                -ForegroundColor DarkGray
        }
        'last' {
            $registry = Read-LauncherRegistry
            $state = Read-LauncherState
            $last = @($state.recent | Where-Object {
                @($registry.projects.id) -contains $_.projectId
            } | Select-Object -First 1)
            if ($last.Count -ne 1) {
                throw 'Недавних проектов пока нет.'
            }
            [void] (Invoke-OpenAndRemember -ProjectId $last[0].projectId)
        }
        'run' {
            if ($inputArguments.Count -lt 2) {
                throw 'Использование: el run <project> [task]'
            }
            if ($inputArguments.Count -ge 3) {
                $registry = Read-LauncherRegistry
                $project = Resolve-LauncherProject `
                    -Registry $registry `
                    -Identity ([string] $inputArguments[1])
                $managerArguments = @(
                    'run',
                    $project.id,
                    [string] $inputArguments[2]
                ) + @($inputArguments | Select-Object -Skip 3)
                Invoke-Manager -Arguments $managerArguments
                $code = $script:LastManagerExitCode
                if (
                    $code -eq 0 -and
                    $inputArguments -notcontains '-DryRun'
                ) {
                    Add-RecentProject -ProjectId $project.id
                }
            }
            else {
                $registry = Read-LauncherRegistry
                $identity = [string] $inputArguments[1]
                $project = @($registry.projects | Where-Object {
                    $_.id.Equals($identity, [StringComparison]::OrdinalIgnoreCase) -or
                    $_.displayName.Equals($identity, [StringComparison]::OrdinalIgnoreCase)
                })
                if ($project.Count -ne 1) {
                    throw "Проект '$identity' не найден."
                }
                $task = Select-ProjectTask -Project $project[0]
                if ($task) {
                    if ($task.id -eq '__workspace') {
                        [void] (Invoke-OpenAndRemember -ProjectId $project[0].id)
                    }
                    else {
                        Invoke-Manager -Arguments @(
                            'run',
                            $project[0].id,
                            $task.id
                        )
                        $code = $script:LastManagerExitCode
                        if ($code -eq 0) {
                            Add-RecentProject -ProjectId $project[0].id
                        }
                    }
                }
            }
        }
        { $_ -in @(
            'add', 'init', 'refresh', 'inspect', 'list', 'tasks', 'status',
            'open', 'remove', 'sync', 'doctor', 'trust-git', 'untrust-git'
        ) } {
            Invoke-Manager -Arguments $inputArguments
        }
        default {
            [void] (Invoke-OpenAndRemember `
                -ProjectId ([string] $inputArguments[0]) `
                -Console:($inputArguments -contains '-Console'))
        }
    }
    if ($null -eq $global:LASTEXITCODE) {
        $global:LASTEXITCODE = 0
    }
}
catch {
    Write-Host
    Write-Host "  ✗ $($_.Exception.Message)" -ForegroundColor Red
    Write-Host
    $global:LASTEXITCODE = 1
    return
}
