# EL Workspace profile module for PowerShell 7.

$script:ELWorkspaceToolRoot = if (
    $env:EL_WORKSPACE_TEST_MODE -eq '1' -and
    $env:EL_WORKSPACE_TEST_ROOT
) {
    [IO.Path]::GetFullPath($env:EL_WORKSPACE_TEST_ROOT)
}
else {
    Join-Path $env:LOCALAPPDATA 'EL-System-Tools\Terminal'
}

function global:el-project {
    & (Join-Path $script:ELWorkspaceToolRoot 'el-project.ps1') @args
}

function global:el {
    & (Join-Path $script:ELWorkspaceToolRoot 'el.ps1') @args
}

function global:el-workspace {
    & (Join-Path $script:ELWorkspaceToolRoot 'el-workspace.ps1') @args
}

function global:Invoke-ELProjectShortcut {
    param(
        [Parameter(Mandatory)][string] $ProjectId,
        [object[]] $Arguments
    )

    if (@($Arguments).Count -eq 0) {
        el $ProjectId
        return
    }
    el run $ProjectId @Arguments
}

function global:app {
    Invoke-ELProjectShortcut -ProjectId 'apprestore' -Arguments @($args)
}

function global:clean {
    Invoke-ELProjectShortcut -ProjectId 'cleantools' -Arguments @($args)
}

function global:site {
    Invoke-ELProjectShortcut -ProjectId 'website' -Arguments @($args)
}

function global:serve {
    el run website dev @args
}

function global:g {
    $gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $gitCommand) {
        throw 'git.exe не найден.'
    }
    if ($args.Count -eq 0) {
        & $gitCommand.Source status --short --branch
    }
    else {
        & $gitCommand.Source @args
    }
}

function global:publish {
    el-workspace publish @args
}

function global:update-tools {
    el-workspace update @args
}

function global:elj {
    $fzfCommand = Get-Command fzf.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $fzfCommand) {
        el
        return
    }

    $projectRows = @(el-project list -Json | ConvertFrom-Json -Depth 20)
    $choices = @($projectRows | ForEach-Object {
        "$($_.ID)`t$($_.Name)`t$($_.Path)"
    })
    if ($choices.Count -eq 0) {
        Write-Host '  Проекты пока не зарегистрированы.' -ForegroundColor DarkGray
        return
    }
    $selected = $choices |
        & $fzfCommand.Source `
            --height=60% `
            --layout=reverse `
            --border=rounded `
            --prompt='EL › ' `
            --header='Проект · путь' `
            --with-nth='2,3'
    if ($LASTEXITCODE -eq 0 -and $selected) {
        el (($selected -split "`t", 2)[0])
    }
}

$script:ELInteractiveSession =
    [Environment]::UserInteractive -and
    -not [Console]::IsInputRedirected -and
    -not [Console]::IsOutputRedirected

if (-not $script:ELInteractiveSession) {
    return
}

$env:VIRTUAL_ENV_DISABLE_PROMPT = '1'

if (Get-Module -ListAvailable -Name Terminal-Icons) {
    Import-Module Terminal-Icons -ErrorAction SilentlyContinue
}

$zoxideCommand = Get-Command zoxide.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($zoxideCommand) {
    $env:_ZO_ECHO = '1'
    $env:_ZO_FZF_OPTS = (
        '--height=60% --layout=reverse --border=rounded ' +
        '--prompt="Jump › " --info=inline'
    )
    try {
        (& $zoxideCommand.Source init powershell | Out-String) |
            Invoke-Expression
    }
    catch {
        Write-Warning 'zoxide не удалось инициализировать; команды el продолжают работать.'
    }
}

$ohMyPosh = Get-Command oh-my-posh.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1
$installedTheme = Join-Path $PSScriptRoot 'themes\el-midnight.omp.json'
$userProfileRoot = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::UserProfile
)
$legacyTheme = Join-Path $userProfileRoot '.config\oh-my-posh\el-midnight.omp.json'
$ohMyPoshConfig = if (Test-Path -LiteralPath $installedTheme -PathType Leaf) {
    $installedTheme
}
else {
    $legacyTheme
}

if ($ohMyPosh -and (Test-Path -LiteralPath $ohMyPoshConfig -PathType Leaf)) {
    try {
        (& $ohMyPosh.Source init pwsh --config $ohMyPoshConfig) |
            Invoke-Expression
    }
    catch {
        Write-Warning 'Oh My Posh не удалось инициализировать; используется стандартный prompt.'
    }
}

if (Get-Module -ListAvailable -Name PSReadLine) {
    Import-Module PSReadLine -ErrorAction SilentlyContinue

    Set-PSReadLineOption -EditMode Windows
    Set-PSReadLineOption -BellStyle None
    Set-PSReadLineOption -HistoryNoDuplicates
    Set-PSReadLineOption -HistorySearchCursorMovesToEnd
    Set-PSReadLineOption -HistorySaveStyle SaveIncrementally
    Set-PSReadLineOption -MaximumHistoryCount 4096

    $supportsVirtualTerminal = $false
    if ($Host.UI.PSObject.Properties.Name -contains 'SupportsVirtualTerminal') {
        $supportsVirtualTerminal = $Host.UI.SupportsVirtualTerminal
    }
    if ($env:WT_SESSION) {
        $supportsVirtualTerminal = $true
    }

    if ($supportsVirtualTerminal) {
        try {
            Set-PSReadLineOption `
                -PredictionSource History `
                -PredictionViewStyle ListView
        }
        catch {
            # Prediction is optional in hosts without a full VT console.
        }
    }

    Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
}
