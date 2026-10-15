# Панель трея Windows для EL Workspace.
# Показывает ту же сводку, что меню-бар на macOS, и открывает #/panel.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$base = if ($env:EL_HOST) { $env:EL_HOST } else { 'http://127.0.0.1:8080' }
$icon = New-Object System.Windows.Forms.NotifyIcon
$icon.Icon = [System.Drawing.SystemIcons]::Information
$icon.Visible = $true
$icon.Text = 'EL Workspace'

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$open = $menu.Items.Add('Открыть EL Workspace')
$open.add_Click({ Start-Process "$base/#/" })
$panel = $menu.Items.Add('Панель')
$panel.add_Click({ Start-Process "$base/#/panel" })
$exit = $menu.Items.Add('Закрыть трей')
$exit.add_Click({
    $icon.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})
$icon.ContextMenuStrip = $menu
$icon.add_Click({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Start-Process "$base/#/panel"
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 30000
$timer.add_Tick({
    try {
        $payload = Invoke-RestMethod -Uri "$base/api/panel" -TimeoutSec 3
        $queue = [int] $payload.queue
        $icon.Text = if ($queue -gt 0) { "EL Workspace · очередь $queue" } else { 'EL Workspace · синхр.' }
    }
    catch {
        $icon.Text = 'EL Workspace · сервер не запущен'
    }
})
$timer.Start()
[System.Windows.Forms.Application]::Run()
