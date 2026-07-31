[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$toolRoot = Split-Path -Parent $PSScriptRoot
$manager = Join-Path $toolRoot 'el-project.ps1'
$launcher = Join-Path $toolRoot 'el.ps1'
$runner = Join-Path $toolRoot 'workspace-pane.ps1'
$registryPath = Join-Path $toolRoot 'projects.json'
$fixtureRoot = Join-Path $PSScriptRoot 'fixtures\pwa'
$fragmentPath = Join-Path (
    [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
) 'Microsoft\Windows Terminal\Fragments\EL.ProjectManager\projects.json'
$profilePath = if (
    $env:EL_WORKSPACE_TEST_MODE -eq '1' -and
    $env:EL_WORKSPACE_TEST_PROFILE
) {
    [IO.Path]::GetFullPath($env:EL_WORKSPACE_TEST_PROFILE)
}
else {
    Join-Path $HOME 'Documents\PowerShell\profile.ps1'
}

function Assert-True {
    param(
        [Parameter(Mandatory)][bool] $Condition,
        [Parameter(Mandatory)][string] $Message
    )

    if (-not $Condition) {
        throw "SMOKE: $Message"
    }
}

function Assert-PowerShellParses {
    param([Parameter(Mandatory)][string] $Path)

    $tokens = $null
    $errors = $null
    [void] [Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref] $tokens,
        [ref] $errors
    )
    Assert-True ($errors.Count -eq 0) "PowerShell parser errors in $Path"
}

foreach ($path in @($manager, $launcher, $runner, $profilePath, $PSCommandPath)) {
    Assert-PowerShellParses -Path $path
}

$projectSchema = Get-Content `
    -LiteralPath (Join-Path $toolRoot 'projects.schema.json') `
    -Raw `
    -Encoding UTF8
$manifestSchema = Get-Content `
    -LiteralPath (Join-Path $toolRoot 'el-project.schema.json') `
    -Raw `
    -Encoding UTF8
[void] ($projectSchema | ConvertFrom-Json -Depth 100)
[void] ($manifestSchema | ConvertFrom-Json -Depth 100)

$exampleManifestPath = Join-Path $toolRoot 'examples\node-pwa.el-project.json'
$exampleManifest = Get-Content -LiteralPath $exampleManifestPath -Raw -Encoding UTF8
Assert-True `
    ($exampleManifest | Test-Json -Schema $manifestSchema) `
    'Node PWA manifest example does not match schema'

$fixtureJson = & $manager inspect $fixtureRoot -Json
Assert-True ($global:LASTEXITCODE -eq 0) 'fixture inspect failed'
$fixture = $fixtureJson | ConvertFrom-Json -Depth 100
Assert-True ($fixture.stack -eq 'pwa') 'fixture stack is not pwa'
Assert-True ($fixture.displayName -eq 'Fixture PWA') 'manifest displayName not applied'
Assert-True ($fixture.manifest.sha256 -match '^[a-f0-9]{64}$') 'manifest hash missing'
Assert-True (@($fixture.tasks.id) -contains 'community-tests') 'manifest task missing'
Assert-True ($fixture.tasks.Count -eq 6) 'unexpected resolved fixture task count'
Assert-True ($fixture.workspace.Count -eq 3) 'fixture workspace was not replaced'

# Regression coverage for Invoke-InitManifest: PowerShell unwraps switch output
# when a stack has zero or one required command. Both cases must stay arrays.
$smokeTempRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    ('el-project-smoke-' + [Guid]::NewGuid().ToString('N'))
[void] [IO.Directory]::CreateDirectory($smokeTempRoot)
try {
    $genericRoot = Join-Path $smokeTempRoot 'generic-project'
    $pythonRoot = Join-Path $smokeTempRoot 'python-project'
    $composeRoot = Join-Path $smokeTempRoot 'compose-project'
    [void] [IO.Directory]::CreateDirectory($genericRoot)
    [void] [IO.Directory]::CreateDirectory($pythonRoot)
    [void] [IO.Directory]::CreateDirectory((Join-Path $composeRoot 'backend\app'))
    [void] [IO.Directory]::CreateDirectory((Join-Path $composeRoot 'backend\tests'))
    [void] [IO.Directory]::CreateDirectory((Join-Path $composeRoot 'frontend'))
    [IO.File]::WriteAllText(
        (Join-Path $pythonRoot 'pyproject.toml'),
        "[project]`nname = 'fixture-python'`nversion = '0.1.0'`n",
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $composeRoot 'docker-compose.yml'),
        "services:`n  api:`n    build: ./backend`n  web:`n    build: ./frontend`n",
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $composeRoot 'backend\requirements.txt'),
        "fastapi==1.0.0`nuvicorn==1.0.0`npytest==1.0.0`n",
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $composeRoot 'backend\app\main.py'),
        "app = object()`n",
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $composeRoot 'backend\tests\test_fixture.py'),
        "def test_fixture():`n    assert True`n",
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $composeRoot 'frontend\package.json'),
        (@{
            name = 'fixture-frontend'
            private = $true
            scripts = [ordered]@{
                dev = 'vite'
                test = 'vitest run'
                lint = 'eslint .'
                build = 'vite build'
            }
        } | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false)
    )

    $composeJson = & $manager inspect $composeRoot -Json
    Assert-True ($global:LASTEXITCODE -eq 0) 'compose fixture inspect failed'
    $composeProject = $composeJson | ConvertFrom-Json -Depth 100
    Assert-True ($composeProject.stack -eq 'compose') 'compose fixture stack is incorrect'
    Assert-True ($composeProject.workspace.Count -eq 3) 'compose workspace is not three-pane'
    Assert-True `
        ((@($composeProject.workspace.task) -join ',') -eq
            'main,backend-shell,frontend-shell') `
        'compose workspace task order is incorrect'
    Assert-True `
        (@($composeProject.tasks.id) -contains 'backend-dev') `
        'compose backend dev task missing'
    Assert-True `
        (@($composeProject.tasks.id) -contains 'frontend-dev') `
        'compose frontend dev task missing'
    Assert-True `
        (@($composeProject.tasks.id) -contains 'full-tests') `
        'compose full test task missing'
    $backendShell = @($composeProject.tasks | Where-Object id -eq 'backend-shell')[0]
    $frontendShell = @($composeProject.tasks | Where-Object id -eq 'frontend-shell')[0]
    Assert-True `
        ($backendShell.steps[0].runner -eq 'workspaceShell' -and
            $backendShell.steps[0].cwd -eq 'backend') `
        'compose backend shell is unsafe or points to the wrong directory'
    Assert-True `
        ($frontendShell.steps[0].runner -eq 'workspaceShell' -and
            $frontendShell.steps[0].cwd -eq 'frontend') `
        'compose frontend shell is unsafe or points to the wrong directory'

    & $manager init $genericRoot -Yes
    Assert-True ($global:LASTEXITCODE -eq 0) 'generic manifest init failed'
    $genericManifest = Get-Content `
        -LiteralPath (Join-Path $genericRoot '.el-project.json') `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 30
    Assert-True `
        ($genericManifest.PSObject.Properties.Name -notcontains 'requirements') `
        'generic manifest unexpectedly has requirements'

    & $manager init $pythonRoot -Yes
    Assert-True ($global:LASTEXITCODE -eq 0) 'python manifest init failed'
    $pythonManifest = Get-Content `
        -LiteralPath (Join-Path $pythonRoot '.el-project.json') `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 30
    Assert-True `
        (@($pythonManifest.requirements.commands).Count -eq 1) `
        'python manifest does not have exactly one requirement'
    Assert-True `
        ($pythonManifest.requirements.commands -contains 'python') `
        'python manifest requirement is incorrect'

    & $manager init $composeRoot -Yes
    Assert-True ($global:LASTEXITCODE -eq 0) 'compose manifest init failed'
    $composeManifest = Get-Content `
        -LiteralPath (Join-Path $composeRoot '.el-project.json') `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 30
    Assert-True ($composeManifest.stack -eq 'compose') 'compose manifest stack is incorrect'
    Assert-True `
        ((@($composeManifest.requirements.commands) -join ',') -eq
            'docker,node,npm,python') `
        'compose manifest requirements are incorrect or duplicated'
}
finally {
    $resolvedSmokeTemp = [IO.Path]::GetFullPath($smokeTempRoot)
    $resolvedSystemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $safeLeaf = Split-Path -Leaf $resolvedSmokeTemp
    if (
        $resolvedSmokeTemp.StartsWith(
            $resolvedSystemTemp,
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        $safeLeaf -like 'el-project-smoke-*' -and
        (Test-Path -LiteralPath $resolvedSmokeTemp)
    ) {
        Remove-Item -LiteralPath $resolvedSmokeTemp -Recurse -Force
    }
}

$registryBeforeHash = (Get-FileHash $registryPath -Algorithm SHA256).Hash
$fragmentBeforeHash = (Get-FileHash $fragmentPath -Algorithm SHA256).Hash
$previewJson = & $manager sync -DryRun
Assert-True ($global:LASTEXITCODE -eq 0) 'sync -DryRun failed'
$preview = $previewJson | ConvertFrom-Json -Depth 100
Assert-True (@($preview.actions).Count -gt 0) 'sync preview has no actions'
Assert-True `
    ((Get-FileHash $registryPath -Algorithm SHA256).Hash -eq $registryBeforeHash) `
    'sync -DryRun changed registry'
Assert-True `
    ((Get-FileHash $fragmentPath -Algorithm SHA256).Hash -eq $fragmentBeforeHash) `
    'sync -DryRun changed fragment'

$registry = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 |
    ConvertFrom-Json -Depth 100
foreach ($project in @($registry.projects)) {
    foreach ($task in @($project.tasks)) {
        $description = & $runner `
            -ProjectId $project.id `
            -TaskId $task.id `
            -Describe
        Assert-True ($global:LASTEXITCODE -eq 0) (
            "runner describe failed for $($project.id)/$($task.id)"
        )
        [void] (($description -join [Environment]::NewLine) |
            ConvertFrom-Json -Depth 30)
    }
}

$taskDryRun = & $manager run website checks -DryRun | ConvertFrom-Json -Depth 30
Assert-True ($taskDryRun.arguments -contains '-TaskId') 'run dry-run lacks TaskId'
Assert-True ($taskDryRun.arguments -contains 'checks') 'run dry-run lacks selected task'

& $manager sync -Check
Assert-True ($global:LASTEXITCODE -eq 0) 'sync -Check failed'

Write-Host
Write-Host '  ✓ EL Project Manager smoke tests passed.' -ForegroundColor Green
