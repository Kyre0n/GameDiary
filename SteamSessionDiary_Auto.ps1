Set-StrictMode -Version Latest

[System.Threading.Thread]::CurrentThread.CurrentCulture =
    [System.Globalization.CultureInfo]::GetCultureInfo("es-ES")

# =================== VARIABLES GLOBALES ===================
$Global:RetroArchRunning = $false
$Global:CurrentRetroArchGame = $null
$Global:HUDProcesses = @{}  # AppID -> Process
$Global:Paused = $false
$Global:ConsoleVisible = $false
$Global:InputLock = $false

# =================== CONFIGURACIÓN ===================
$Libraries       = @("C:\Program Files (x86)\Steam\steamapps")
$LogFolder       = "C:\Users\Kyreon\MENTE-DIGITAL\Personal\Videojuegos"
$CheckInterval   = 30
$IdleInterval    = 30
$ActiveInterval  = 5
$ShutdownGraceSeconds = 5

$GameFolders = @{
    1 = "Backlog"
    2 = "Continuous"
    3 = "Finished"
}

$EACOverridesPath = "C:\LaunchBox\scripts\SteamEACOverrides.json"

$TrayIconPath = "C:\LaunchBox\scripts\SteamSessionDiary.ico"

$LauncherOverridesPath = "C:\LaunchBox\scripts\LauncherOverrides.json"

$Global:EACOverrides = @{}
if (Test-Path $EACOverridesPath) {
    $jsonObj = Get-Content $EACOverridesPath -Raw | ConvertFrom-Json
    foreach ($p in $jsonObj.PSObject.Properties) {
        $Global:EACOverrides[$p.Name] = $p.Value
    }
}

$Global:LauncherOverrides = @{}

if (Test-Path $LauncherOverridesPath) {
    try {
        $jsonObj = Get-Content $LauncherOverridesPath -Raw | ConvertFrom-Json
        foreach ($p in $jsonObj.PSObject.Properties) {
            $Global:LauncherOverrides[$p.Name] = $p.Value
        }
    } catch {
        Write-Host "❌ Error leyendo LauncherOverrides.json"
    }
}

if (-not (Test-Path $LogFolder)) {
    New-Item -ItemType Directory -Path $LogFolder | Out-Null
}

# =================== WIN32 HELPERS ===================
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
}
"@

$ConsoleHandle = [Win32]::GetConsoleWindow()

# Estados de ventana
$SW_HIDE    = 0
$SW_RESTORE = 9
$SW_MINIMIZE = 6

# =================== TRAY ICON ===================
Add-Type -AssemblyName System.Windows.Forms
$notify = New-Object System.Windows.Forms.NotifyIcon

if ($TrayIconPath -and (Test-Path $TrayIconPath)) {
    $notify.Icon = New-Object System.Drawing.Icon($TrayIconPath)
} else {
    $notify.Icon = [System.Drawing.SystemIcons]::Application
}

$notify.Text = "SteamSessionDiary"
$notify.Visible = $true

# Owner invisible para poder mostrar el ContextMenu correctamente
$MenuOwner = New-Object System.Windows.Forms.Form
$MenuOwner.ShowInTaskbar = $false
$MenuOwner.FormBorderStyle = 'None'
$MenuOwner.Opacity = 0
$MenuOwner.Size = New-Object System.Drawing.Size(1,1)
$MenuOwner.StartPosition = 'Manual'
$MenuOwner.Location = New-Object System.Drawing.Point(-32000,-32000)
$MenuOwner.Show()

$menu = New-Object System.Windows.Forms.ContextMenu

$showMenu = New-Object System.Windows.Forms.MenuItem "Mostrar consola"
$showMenu.add_Click({
    Show-Console
})

$hideMenu = New-Object System.Windows.Forms.MenuItem "Ocultar consola"
$hideMenu.add_Click({
    Hide-Console
})

$pauseMenu = New-Object System.Windows.Forms.MenuItem "Pausar detección"
$pauseMenu.add_Click({
    $Global:Paused = -not $Global:Paused
    if ($Global:Paused) {
        $pauseMenu.Text = "Reanudar detección"
        $notify.Text = "SteamSessionDiary (PAUSADO)"
    } else {
        $pauseMenu.Text = "Pausar detección"
        $notify.Text = "SteamSessionDiary"
    }
})

$exitMenu = New-Object System.Windows.Forms.MenuItem "Salir"
$exitMenu.add_Click({
    $notify.Visible = $false
    try { Close-AllGameHUDs } catch {}
    Stop-Process -Id $PID -Force
})

$menu.MenuItems.Add($showMenu) | Out-Null
$menu.MenuItems.Add($hideMenu) | Out-Null
$menu.MenuItems.Add("-") | Out-Null
$menu.MenuItems.Add($pauseMenu) | Out-Null
$menu.MenuItems.Add("-") | Out-Null
$menu.MenuItems.Add($exitMenu) | Out-Null

$notify.ContextMenu = $menu

$notify.add_MouseUp({
    param($sender, $e)

    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        $MenuOwner.Activate()
        $notify.ContextMenu.Show($MenuOwner, $MenuOwner.PointToClient([System.Windows.Forms.Cursor]::Position))
    }
})

$notify.add_DoubleClick({
    Toggle-Console
})

# Ocultar consola al iniciar
[Win32]::ShowWindow($ConsoleHandle, $SW_HIDE) | Out-Null

# ------------------- HUD -------------------

function Show-GameHUD {
    param(
        [string]$GameKey,
        [string]$GameTitle
    )

    # Si ya hay HUD para ese juego, no volverlo a crear
    if ($Global:HUDProcesses.ContainsKey($GameKey)) { return }

    $TempHUD = Join-Path $env:TEMP "GameHUD_$([guid]::NewGuid()).ps1"

    $HUDScript = @'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;

public class Win32 {
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(
        IntPtr hWnd, IntPtr hWndInsertAfter,
        int X, int Y, int cx, int cy, uint uFlags);

    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);

    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_SHOWWINDOW = 0x0040;

    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateRoundRectRgn(
        int l, int t, int r, int b, int w, int h);

    [DllImport("user32.dll")]
    public static extern bool ReleaseCapture();

    [DllImport("user32.dll")]
    public static extern int SendMessage(
        IntPtr hWnd, int Msg, int wParam, int lParam);
}
"@

$GameTitle = "{0}" -f $env:HUD_GAME_TITLE
$StartTime = Get-Date

$form = New-Object System.Windows.Forms.Form
$form.Size = New-Object System.Drawing.Size(360,130)
$form.FormBorderStyle = 'None'
$form.BackColor = [System.Drawing.Color]::FromArgb(24,24,24)
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.Opacity = 0.85

$drag = {
    if ($_.Button -eq 'Left') {
        [Win32]::ReleaseCapture() | Out-Null
        [Win32]::SendMessage($form.Handle,0xA1,2,0) | Out-Null
    }
}
$form.Add_MouseDown($drag)

$top = New-Object System.Windows.Forms.Panel
$top.Dock = 'Top'
$top.Height = 6
$top.BackColor = [System.Drawing.Color]::FromArgb(0,170,255)
$top.Add_MouseDown($drag)
$form.Controls.Add($top)

$title = New-Object System.Windows.Forms.Label
$title.Text = "🎮 $GameTitle"
$title.ForeColor = [System.Drawing.Color]::White
$title.Font = New-Object System.Drawing.Font("Segoe UI Semibold",14)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(18,20)
$title.Add_MouseDown($drag)
$form.Controls.Add($title)

$timeLabel = New-Object System.Windows.Forms.Label
$timeLabel.ForeColor = [System.Drawing.Color]::Gainsboro
$timeLabel.Font = New-Object System.Drawing.Font("Segoe UI",10)
$timeLabel.AutoSize = $true
$timeLabel.Location = New-Object System.Drawing.Point(20,60)
$timeLabel.Add_MouseDown($drag)
$form.Controls.Add($timeLabel)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    $elapsed = (Get-Date) - $StartTime
    $timeLabel.Text = "Tiempo jugado: " + $elapsed.ToString("hh\:mm\:ss")
})
$timer.Start()

$form.Add_Shown({
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen
    $b = $screen.Bounds
    $margin = 20

    [Win32]::SetWindowPos(
        $form.Handle,
        [Win32]::HWND_TOPMOST,
        $b.Right - $form.Width - $margin,
        $b.Top + $margin,
        0, 0,
        [Win32]::SWP_NOSIZE -bor
        [Win32]::SWP_NOACTIVATE -bor
        [Win32]::SWP_SHOWWINDOW
    ) | Out-Null

    $rgn = [Win32]::CreateRoundRectRgn(0,0,$form.Width,$form.Height,25,25)
    $form.Region = [System.Drawing.Region]::FromHrgn($rgn)
})

[System.Windows.Forms.Application]::Run($form)
'@

    Set-Content -Path $TempHUD -Value $HUDScript -Encoding UTF8
    $env:HUD_GAME_TITLE = $GameTitle

    $p = Start-Process powershell `
        "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$TempHUD`"" `
        -PassThru

    $Global:HUDProcesses[$GameKey] = $p
}

function Close-GameHUD {
    param([string]$GameKey)

    if (-not $GameKey) { return }

    if ($Global:HUDProcesses.ContainsKey($GameKey)) {
        try { $Global:HUDProcesses[$GameKey].Kill() } catch {}
        $Global:HUDProcesses.Remove($GameKey)
    }
}

function Close-AllGameHUDs {
    foreach ($k in @($Global:HUDProcesses.Keys)) {
        Close-GameHUD -GameKey $k
    }
}

# ------------------- ESTADO -------------------

$RunningGames      = @{}
$ProcessStartTimes = @{}
$PendingShutdown = @{}
$GameLogFiles = @{}   # GameKey/AppID -> FullPath md
$GameTitleCache = @{}
$SteamManifestCache = @{}   # AppID -> @{ Title=...; InstallDir=... }
$SteamCacheLastRefresh = Get-Date "2000-01-01"
$SteamCacheRefreshSeconds = 300  # 5 min
$Global:CloseQueue = New-Object System.Collections.Queue

Write-Host "Detectando juegos en ejecución..."

# =================== INPUT HELPERS ===================
function Ask-Input {
    param([string]$Prompt)

    while ($Global:InputLock) {
        Start-Sleep -Milliseconds 150
    }

    $Global:InputLock = $true
    try {
        Show-Console
        $res = Read-Host $Prompt
        Hide-Console
        return $res
    }
    finally {
        $Global:InputLock = $false
    }
}

function Get-DateYMD {
    return (Get-Date).ToString("yyyy-MM-dd")
}

function Format-DateTime {
    param([DateTime]$dt)
    return $dt.ToString("dd/MM/yyyy HH:mm:ss")
}

function Format-TimeSpan {
    param([TimeSpan]$ts)
    return $ts.ToString("hh\:mm\:ss")
}

function Get-OrCreate-GameLogFile {
    param([string]$BasePath,[string]$GameTitle)

    $fileName = "$GameTitle.md"
    $existing = Get-ChildItem $BasePath -Recurse -Filter $fileName -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existing) { return $existing.FullName }

    Write-Host "No existe registro para '$GameTitle'"
    foreach ($k in $GameFolders.Keys | Sort-Object) {
        Write-Host " $k) $($GameFolders[$k])"
    }

    do { $choice = Ask-Input "Elige una opción" }
    until ($GameFolders.ContainsKey([int]$choice))

    $target = Join-Path $BasePath $GameFolders[[int]$choice]
    if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target | Out-Null }

    $full = Join-Path $target $fileName
    "## Game sessions`n" | Set-Content -Path $full -Encoding UTF8
    return $full
}

function Force-Foreground {
    param([IntPtr]$Handle)

    [Win32]::ShowWindow($Handle, $SW_RESTORE) | Out-Null
    Start-Sleep -Milliseconds 50

    [Win32]::SetForegroundWindow($Handle) | Out-Null
    Start-Sleep -Milliseconds 50

    # Truco anti Windows-focus-block
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.SendKeys]::SendWait("%")
}

function Show-Console {
    [Win32]::ShowWindow($ConsoleHandle, $SW_RESTORE) | Out-Null
    Start-Sleep -Milliseconds 80
    Force-Foreground -Handle $ConsoleHandle
    $Global:ConsoleVisible = $true
}

function Hide-Console {
    [Win32]::ShowWindow($ConsoleHandle, $SW_HIDE) | Out-Null
    $Global:ConsoleVisible = $false
}

function Toggle-Console {
    if ($Global:ConsoleVisible) { Hide-Console } else { Show-Console }
}

Hide-Console

function Get-SteamRunningAppIds {
    # Detecta juegos Steam activos leyendo la registry de Steam
    $steamReg = "HKCU:\Software\Valve\Steam\Apps"
    if (-not (Test-Path $steamReg)) { return @() }

    $running = @()

    Get-ChildItem $steamReg -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $appid = $_.PSChildName
            $p = Get-ItemProperty $_.PSPath -ErrorAction Stop

            # Running = 1 cuando Steam considera el juego en ejecución
            if ($p.Running -eq 1) {
                $running += [int]$appid
            }
        } catch {}
    }

    return $running
}

function Refresh-SteamManifestCache {
    $now = Get-Date
    if (($now - $SteamCacheLastRefresh).TotalSeconds -lt $SteamCacheRefreshSeconds) {
        return
    }

    $SteamCacheLastRefresh = $now
    $SteamManifestCache.Clear()

    foreach ($lib in $Libraries) {
        if (-not (Test-Path $lib)) { continue }

        Get-ChildItem "$lib\appmanifest_*.acf" -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $content = Get-Content $_.FullName -Raw

                if ($content -match '"appid"\s+"(\d+)"') { $AppID = [int]$matches[1] } else { return }
                if ($content -match '"installdir"\s+"(.+)"') { $InstallDir = $matches[1] } else { return }

                if ($InstallDir -match 'Steamworks|SteamVR|Shared|Redist|_CommonRedist|Driver') { return }

                $title = $null
                if ($content -match '"name"\s+"(.+)"') {
                    $title = ($matches[1] -replace '[^a-zA-Z0-9]', ' ' -replace '\s+', ' ').Trim()
                } else {
                    $title = "Steam_$AppID"
                }

                $SteamManifestCache[$AppID] = @{
                    Title      = $title
                    InstallDir = $InstallDir
                }

                if (-not $RunningGames.ContainsKey($AppID)) {
                    $RunningGames[$AppID] = $false
                    $ProcessStartTimes[$AppID] = $null
                }
            } catch {}
        }
    }
}

# ------------------- EPIC -------------------

function Get-EpicGames {
    $manifestPath = "C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests"
    if (-not (Test-Path $manifestPath)) { return @() }

    Get-ChildItem $manifestPath -Filter *.item -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $json = Get-Content $_.FullName -Raw | ConvertFrom-Json
            if ($json.InstallLocation -and $json.LaunchExecutable) {
                $exe = Join-Path $json.InstallLocation $json.LaunchExecutable
                if (Test-Path $exe) {
                    [PSCustomObject]@{
                        Platform = "Epic"
                        AppID    = "EPIC_$($_.BaseName)"
                        Title    = ($json.DisplayName `
                                        -replace '[^a-zA-Z0-9]', ' ' `
                                        -replace '\s+', ' ').Trim()

                        ExePath  = $exe
                    }
                }
            }
        } catch {}
    }
}

# ------------------- GOG -------------------

function Get-GogGames {
    $baseKey = "HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games"
    if (-not (Test-Path $baseKey)) { return @() }

    Get-ChildItem $baseKey | ForEach-Object {
        try {
            $p = Get-ItemProperty $_.PSPath
            if ($p.exe -and (Test-Path $p.exe)) {
                [PSCustomObject]@{
                    Platform = "GOG"
                    AppID    = "GOG_$($_.PSChildName)"
                    Title    = ($p.gameName `
                                    -replace '[^a-zA-Z0-9]', ' ' `
                                    -replace '\s+', ' ').Trim()

                    ExePath  = $p.exe
                }
            }
        } catch {}
    }
}

# ------------------- Retroarch -------------------
$Global:RetroArchLastCmd = $null

function Get-RetroArchRunningGame {

    $p = Get-Process -Name "retroarch" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) { return $null }

    # Solo si RetroArch existe, usamos CIM 1 vez para CommandLine
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue
    if (-not $proc -or -not $proc.CommandLine) { return $null }

    $cmd = ($proc.CommandLine -replace '\s+', ' ').Trim()

    # Si la commandline no cambió, devuelve lo mismo sin recalcular
    if ($Global:RetroArchLastCmd -eq $cmd -and $Global:CurrentRetroArchGame) {
        return $Global:CurrentRetroArchGame
    }

    $Global:RetroArchLastCmd = $cmd

    if ($cmd -match '"([^"]+\.(cue|iso|chd|bin|zip|7z|nes|sfc|smc|gba|gb|gbc))"') {

        $romPath = $matches[1]

        $cleanTitle = (
            [System.IO.Path]::GetFileNameWithoutExtension($romPath) `
                -replace '[^a-zA-Z0-9]', ' ' `
                -replace '\s+', ' '
        ).Trim()

        return @{
            AppID   = "RETRO_$cleanTitle"
            Title   = $cleanTitle
            RomPath = $romPath
            Process = $proc
        }
    }

    return $null
}

# ------------------- EXTERNOS -------------------

$ExternalGames = @{}
@(Get-EpicGames) + @(Get-GogGames) | ForEach-Object {
    $ExternalGames[$_.AppID] = $_
}

function Ask-GameFolder {
    param([string]$GameTitle)

    # Restaurar PS al frente antes de pedir input
    Force-Foreground -Handle $ConsoleHandle

    Write-Host ""
    Write-Host "No existe registro para '$GameTitle'"
    foreach ($k in $GameFolders.Keys | Sort-Object) {
        Write-Host " $k) $($GameFolders[$k])"
    }

    do {
        $choice = Read-Host "Elige una opción"
    } until ($GameFolders.ContainsKey([int]$choice))

    $targetFolder = Join-Path $LogFolder $GameFolders[[int]$choice]
    if (-not (Test-Path $targetFolder)) {
        New-Item -ItemType Directory -Path $targetFolder | Out-Null
    }

    $fullPath = Join-Path $targetFolder "$GameTitle.md"

    "`n## Game sessions`n" | Set-Content -Path $fullPath -Encoding UTF8

    return $fullPath
}

# ------------------- BUCLE PRINCIPAL -------------------

while ($true) {

        if ($Global:Paused) {
        Start-Sleep -Seconds $CheckInterval
        continue
    }

    # ==================== STEAM (por AppID Running en Registry) ====================

    Refresh-SteamManifestCache
    $SteamRunningAppIds = Get-SteamRunningAppIds

    foreach ($AppID in $SteamManifestCache.Keys) {

        $GameTitle = $SteamManifestCache[$AppID].Title

        $isRunningNow = ($SteamRunningAppIds -contains $AppID)

        if ($isRunningNow -and -not $RunningGames[$AppID]) {

            $RunningGames[$AppID] = $true
            $ProcessStartTimes[$AppID] = Get-Date

            $LogFile = Get-OrCreate-GameLogFile -BasePath $LogFolder -GameTitle $GameTitle
            $GameLogFiles[$AppID] = $LogFile
            $date  = Get-DateYMD
            $start = Format-DateTime $ProcessStartTimes[$AppID]

            Add-Content -Path $LogFile -Value "`n#### [[$date]] (Steam)`n`t`t$start" -NoNewline

            Show-GameHUD -GameKey $AppID -GameTitle $GameTitle

            Write-Host "🎮 Juego iniciado (Steam): $GameTitle (AppID $AppID)"
        }
        elseif (-not $isRunningNow -and $RunningGames[$AppID]) {

            if (-not $PendingShutdown.ContainsKey($AppID)) {
                $PendingShutdown[$AppID] = Get-Date
                continue
            }

            $elapsed = (Get-Date) - $PendingShutdown[$AppID]
            if ($elapsed.TotalSeconds -lt $ShutdownGraceSeconds) { continue }

            Close-GameHUD -GameKey $AppID

            $EndTime   = Get-Date
            $StartTime = $ProcessStartTimes[$AppID]

            $LogFile = $GameLogFiles[$AppID]

            $Global:CloseQueue.Enqueue([PSCustomObject]@{
                AppID     = $AppID
                Title     = $GameTitle
                Platform  = "Steam"
                StartTime = $StartTime
                EndTime   = $EndTime
                LogFile   = $LogFile
            })

            $RunningGames[$AppID] = $false
            $ProcessStartTimes[$AppID] = $null
            $PendingShutdown.Remove($AppID)
            $GameLogFiles.Remove($AppID) | Out-Null

            Write-Host "✅ Juego cerrado (Steam): $GameTitle (AppID $AppID)"
        }
    }
    
    $processNames = @{}
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        $processNames[$_.ProcessName.ToLower()] = $true
    }

    # ==================== EPIC + GOG ====================

    foreach ($ext in $ExternalGames.Values) {

        $exeName = [IO.Path]::GetFileNameWithoutExtension($ext.ExePath)

        $p = $processNames.ContainsKey($exeName.ToLower())

        # ---------- INICIO ----------
        if ($p -and -not $RunningGames[$ext.AppID]) {

            $RunningGames[$ext.AppID] = $true
            $ProcessStartTimes[$ext.AppID] = Get-Date

            $LogFile = Get-OrCreate-GameLogFile -BasePath $LogFolder -GameTitle $ext.Title
            $GameLogFiles[$ext.AppID] = $LogFile
            $date  = Get-DateYMD
            $start = Format-DateTime $ProcessStartTimes[$ext.AppID]

            Add-Content $LogFile "`n#### [[$date]] ($($ext.Platform))`n`t`t$start" -NoNewline

            Show-GameHUD -GameKey $ext.AppID -GameTitle $ext.Title

            Write-Host "🎮 Juego iniciado ($($ext.Platform)): $($ext.Title)"
        }

        # ---------- CIERRE ----------
        elseif (-not $p -and $RunningGames[$ext.AppID]) {

            # Ventana de gracia para evitar falsos cierres (launchers / reinicios)
            if (-not $PendingShutdown.ContainsKey($ext.AppID)) {
                $PendingShutdown[$ext.AppID] = Get-Date
                continue
            }

            $elapsed = (Get-Date) - $PendingShutdown[$ext.AppID]
            if ($elapsed.TotalSeconds -lt $ShutdownGraceSeconds) { continue }

            Close-GameHUD -GameKey $ext.AppID

            $EndTime   = Get-Date
            $StartTime = $ProcessStartTimes[$ext.AppID]

            $Global:CloseQueue.Enqueue([PSCustomObject]@{
                AppID     = $ext.AppID
                Title     = $ext.Title
                Platform  = $ext.Platform
                StartTime = $StartTime
                EndTime   = $EndTime
                LogFile  = $GameLogFiles[$ext.AppID]
            })

            $RunningGames[$ext.AppID] = $false
            $ProcessStartTimes[$ext.AppID] = $null

            if ($PendingShutdown.ContainsKey($ext.AppID)) {
                $PendingShutdown.Remove($ext.AppID)
            }
            $GameLogFiles.Remove($ext.AppID) | Out-Null

            Write-Host "✅ Juego cerrado ($($ext.Platform)): $($ext.Title)"
        }


    }

    # ==================== LAUNCHERS (Riot / Ankama / etc) ====================

    foreach ($key in $Global:LauncherOverrides.Keys) {

        $cfg = $Global:LauncherOverrides[$key]

        $hasExe      = ($cfg.PSObject.Properties.Match("Exe").Count -gt 0)
        $hasLauncher = ($cfg.PSObject.Properties.Match("LauncherExe").Count -gt 0)
        $hasTarget   = ($cfg.PSObject.Properties.Match("TargetExe").Count -gt 0)

        # Inicializar estado
        if (-not $RunningGames.ContainsKey($key)) {
            $RunningGames[$key] = $false
            $ProcessStartTimes[$key] = $null
        }

        # Variables seguras
        $launcherProc = $null
        $targetProc   = $null
        $directProc   = $null

        # ----------------- MODO EJECUTABLE -----------------
        if ($hasExe) {

            $exeName = [IO.Path]::GetFileNameWithoutExtension($cfg.Exe)
            $directProc = Get-Process -Name $exeName -ErrorAction SilentlyContinue

            # INICIO
            if ($directProc -and -not $RunningGames[$key]) {

                $RunningGames[$key] = $true
                $ProcessStartTimes[$key] = Get-Date

                $LogFile = Get-OrCreate-GameLogFile -BasePath $LogFolder -GameTitle $cfg.Title
                $GameLogFiles[$key] = $LogFile
                $date  = Get-DateYMD
                $start = Format-DateTime $ProcessStartTimes[$key]

                Add-Content -Path $LogFile -Value "`n#### [[$date]] ($($cfg.Platform))`n`t`t$start" -NoNewline

                Show-GameHUD -GameKey $key -GameTitle $cfg.Title

                Write-Host "🎮 Juego iniciado ($($cfg.Platform)): $($cfg.Title)"
            }

            # CIERRE
            elseif (-not $directProc -and $RunningGames[$key]) {

                if (-not $PendingShutdown.ContainsKey($key)) {
                    $PendingShutdown[$key] = Get-Date
                    continue
                }

                $elapsed = (Get-Date) - $PendingShutdown[$key]
                if ($elapsed.TotalSeconds -lt $ShutdownGraceSeconds) { continue }

                Close-GameHUD -GameKey $key

                $EndTime   = Get-Date
                $StartTime = $ProcessStartTimes[$key]

                $LogFile = $GameLogFiles[$key]

                $Global:CloseQueue.Enqueue([PSCustomObject]@{
                    AppID     = $key
                    Title     = $cfg.Title
                    Platform  = $cfg.Platform
                    StartTime = $StartTime
                    EndTime   = $EndTime
                    LogFile   = $LogFile
                })

                $RunningGames[$key] = $false
                $ProcessStartTimes[$key] = $null

                if ($PendingShutdown.ContainsKey($key)) {
                    $PendingShutdown.Remove($key)
                }

                $GameLogFiles.Remove($key) | Out-Null

                Write-Host "✅ Juego cerrado ($($cfg.Platform)): $($cfg.Title)"
            }

            continue
        }

        # ----------------- MODO LAUNCHER -----------------
        if ($hasLauncher -and $hasTarget) {

            $launcherExe = [IO.Path]::GetFileNameWithoutExtension($cfg.LauncherExe)
            $targetExe   = [IO.Path]::GetFileNameWithoutExtension($cfg.TargetExe)

            $launcherProc = Get-Process -Name $launcherExe -ErrorAction SilentlyContinue
            $targetProc   = Get-Process -Name $targetExe   -ErrorAction SilentlyContinue

            # INICIO = cuando aparece el EXE real
            if ($targetProc -and -not $RunningGames[$key]) {

                $RunningGames[$key] = $true
                $ProcessStartTimes[$key] = Get-Date

                $LogFile = Get-OrCreate-GameLogFile -BasePath $LogFolder -GameTitle $cfg.Title
                $GameLogFiles[$key] = $LogFile
                $date  = Get-DateYMD
                $start = Format-DateTime $ProcessStartTimes[$key]

                Add-Content -Path $LogFile -Value "`n#### [[$date]] ($($cfg.Platform))`n`t`t$start" -NoNewline

                Show-GameHUD -GameKey $key -GameTitle $cfg.Title

                Write-Host "🎮 Juego iniciado ($($cfg.Platform)): $($cfg.Title)"
            }

            # CIERRE = cuando desaparece el EXE real
            elseif (-not $targetProc -and $RunningGames[$key]) {

                if (-not $PendingShutdown.ContainsKey($key)) {
                    $PendingShutdown[$key] = Get-Date
                    continue
                }

                $elapsed = (Get-Date) - $PendingShutdown[$key]
                if ($elapsed.TotalSeconds -lt $ShutdownGraceSeconds) { continue }

                Close-GameHUD -GameKey $key

                $EndTime   = Get-Date
                $StartTime = $ProcessStartTimes[$key]

                $LogFile = Get-OrCreate-GameLogFile -BasePath $LogFolder -GameTitle $cfg.Title

                $LogFile = $GameLogFiles[$key]

                $Global:CloseQueue.Enqueue([PSCustomObject]@{
                    AppID     = $key
                    Title     = $cfg.Title
                    Platform  = $cfg.Platform
                    StartTime = $StartTime
                    EndTime   = $EndTime
                    LogFile   = $LogFile
                })

                $RunningGames[$key] = $false
                $ProcessStartTimes[$key] = $null

                if ($PendingShutdown.ContainsKey($key)) {
                    $PendingShutdown.Remove($key)
                }

                Write-Host "✅ Juego cerrado ($($cfg.Platform)): $($cfg.Title)"
            }
        }
    }

    # ------------------- DETECCIÓN RETROARCH -------------------
    $raGame = Get-RetroArchRunningGame

    # ---------- INICIO ----------
    if ($raGame -and -not $Global:RetroArchRunning) {

        $Global:RetroArchRunning = $true
        $Global:CurrentRetroArchGame = $raGame

        Write-Host "▶ RetroArch iniciado: $($raGame.Title)"
        if (-not $RunningGames.ContainsKey($raGame.AppID)) { $RunningGames[$raGame.AppID] = $false; $ProcessStartTimes[$raGame.AppID] = $null }

        $ProcessStartTimes[$raGame.AppID] = Get-Date
        $LogFile = Get-OrCreate-GameLogFile -BasePath $LogFolder -GameTitle $raGame.Title
        $GameLogFiles[$raGame.AppID] = $LogFile
        $date = Get-DateYMD
        $start = Format-DateTime $ProcessStartTimes[$raGame.AppID]
        $entry = "`n#### [[$date]] (RetroArch)`n`t`t$start"
        Add-Content -Path $LogFile -Value $entry -NoNewline

        Show-GameHUD -GameKey $raGame.AppID -GameTitle $raGame.Title
        $RunningGames[$raGame.AppID] = $true
        Write-Host "Juego iniciado (RetroArch): $($raGame.Title)"
    }

    # ---------- CIERRE ----------
    elseif (-not $raGame -and $Global:RetroArchRunning) {

        Close-GameHUD -GameKey $Global:CurrentRetroArchGame.AppID

        $EndTime   = Get-Date
        $StartTime = $ProcessStartTimes[$Global:CurrentRetroArchGame.AppID]

        $LogFile = $GameLogFiles[$Global:CurrentRetroArchGame.AppID]

        $Global:CloseQueue.Enqueue([PSCustomObject]@{
            AppID     = $Global:CurrentRetroArchGame.AppID
            Title     = $Global:CurrentRetroArchGame.Title
            Platform  = "RetroArch"
            StartTime = $StartTime
            EndTime   = $EndTime
            LogFile   = $LogFile
        })

        $RunningGames[$Global:CurrentRetroArchGame.AppID] = $false
        $ProcessStartTimes[$Global:CurrentRetroArchGame.AppID] = $null
        Write-Host "Guardado (RetroArch): $LogFile"

        $Global:RetroArchRunning = $false
        $Global:CurrentRetroArchGame = $null
        $GameLogFiles.Remove($Global:CurrentRetroArchGame.AppID) | Out-Null
    }

    # ==================== PROCESAR COLA DE CIERRES (1 por 1) ====================
    if (-not $Global:InputLock -and $Global:CloseQueue.Count -gt 0) {

        $item = $Global:CloseQueue.Dequeue()

        $Notes  = Ask-Input "Comentarios de la sesión ($($item.Title))"
        $Rating = Ask-Input "Valoración (0-5, decimales permitidos) ($($item.Title))"

        $Duration = $item.EndTime - $item.StartTime

        $endF = Format-DateTime $item.EndTime
        $durF = Format-TimeSpan $Duration

        $ratingClean = ($Rating -replace ',', '.').Trim()
        if (-not ($ratingClean -match '^\d+(\.\d+)?$')) {
            $ratingClean = "?"
        } else {
            $ratingNum = [double]$ratingClean
            if ($ratingNum -lt 0) { $ratingNum = 0 }
            if ($ratingNum -gt 5) { $ratingNum = 5 }
            $ratingClean = $ratingNum.ToString("0.##", [System.Globalization.CultureInfo]::InvariantCulture)
        }

        $stars = "![estrellas](https://starrating-beta.vercel.app/$ratingClean/)"

        Add-Content -Path $item.LogFile -Value " ---------- Played: $durF ---------- $endF`n$Notes`nRating: $stars ($ratingClean/5)`n"
    }

    $anyRunning = ($RunningGames.Values | Where-Object { $_ -eq $true } | Select-Object -First 1)
    if ($anyRunning) {
        Start-Sleep -Seconds $ActiveInterval
    } else {
        Start-Sleep -Seconds $IdleInterval
    }

}