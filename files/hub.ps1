param([switch]$NoBrowser, [switch]$NoUpdate)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Web = Join-Path $Root 'web'
$SettingsFile = Join-Path $Root 'settings.json'
$RunFile = Join-Path $Root 'run.json'
$LogFile = Join-Path $Root 'hub.log'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$MarkBegin = '// >>> Sven Coop Hub (sv_lan automatico)'
$MarkEnd = '// <<< Sven Coop Hub'

$Version = '0.0.0'
$versionFile = Join-Path $Root 'version.txt'
if (Test-Path $versionFile) { $Version = (Get-Content $versionFile -Raw).Trim() }

function Log($m) {
    try {
        # el log no crece sin limite: si pasa de 200 KB, se queda con las ultimas 200 lineas
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 200KB) { $keep = Get-Content $LogFile -Tail 200; Set-Content $LogFile $keep -Encoding UTF8 }
        Add-Content -Path $LogFile -Value ("{0} {1}" -f (Get-Date -Format s), $m)
    } catch {}
}

function Get-Changelog {
    $f = Join-Path $Root 'changelog.json'
    if (-not (Test-Path $f)) { return @() }
    try {
        # PowerShell 5.1 devuelve el arreglo JSON como un solo objeto: hay que recorrerlo para aplanarlo
        $out = @(); foreach ($e in (Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json)) { $out += $e }
        return $out
    }
    catch { return @() }
}

function Get-SteamPath {
    $p = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if ($p) { return ($p -replace '/', '\') }
    'C:\Program Files (x86)\Steam'
}

function Find-Game {
    $steam = Get-SteamPath
    $libs = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += ($m.Groups[1].Value -replace '\\\\', '\') }
    }
    foreach ($l in ($libs | Select-Object -Unique)) {
        $d = Join-Path $l 'steamapps\common\Sven Co-op'
        if (Test-Path (Join-Path $d 'svencoop.exe')) { return $d }
    }
    return $null
}

function Get-SteamUser {
    $vdf = Join-Path (Get-SteamPath) 'config\loginusers.vdf'
    if (-not (Test-Path $vdf)) { return $null }
    $best = $null; $bestScore = -1
    foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"(7656\d{13})"\s*\{(.*?)\}', 'Singleline')) {
        $body = $m.Groups[2].Value
        $name = [regex]::Match($body, '"PersonaName"\s+"([^"]*)"').Groups[1].Value
        $ts = [regex]::Match($body, '"timestamp"\s+"(\d+)"').Groups[1].Value
        $score = 0; if ($ts) { $score = [int64]$ts }
        if ($body -match '"MostRecent"\s+"1"') { $score += 100000000000 }
        if ($score -gt $bestScore) {
            $acc = [int64]$m.Groups[1].Value - 76561197960265728
            $best = @{ name = $name; steamId = ('STEAM_0:{0}:{1}' -f ($acc % 2), [math]::Floor($acc / 2)) }
            $bestScore = $score
        }
    }
    return $best
}

function Read-Settings {
    if (Test-Path $SettingsFile) { try { return (Get-Content $SettingsFile -Raw | ConvertFrom-Json) } catch {} }
    return $null
}

function Test-AutoLan($game) {
    $f = Join-Path $game 'svencoop\listenserver.cfg'
    (Test-Path $f) -and ((Get-Content $f -Raw) -like "*$MarkBegin*")
}

function Set-AutoLan($game, [bool]$on) {
    $f = Join-Path $game 'svencoop\listenserver.cfg'
    $bak = $f + '.hubbak'
    if (-not (Test-Path $bak) -and (Test-Path $f)) { Copy-Item $f $bak }
    $txt = ''
    if (Test-Path $f) { $txt = Get-Content $f -Raw }
    $txt = [regex]::Replace($txt, '(?s)\r?\n?' + [regex]::Escape($MarkBegin) + '.*?' + [regex]::Escape($MarkEnd) + '\r?\n?', "`r`n")
    if ($on) { $txt = $txt.TrimEnd() + "`r`n`r`n$MarkBegin`r`nsv_lan 0`r`n$MarkEnd`r`n" }
    Write-Atomic $f $txt
}

$HubWinSource = @"
using System;
using System.Runtime.InteropServices;
public static class HubWin {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(int a, int b, bool f);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("kernel32.dll")] static extern int GetCurrentThreadId();
    // Trae el juego al frente aunque otra app (Claude, Discord...) tenga el foco, para que capture el mouse
    public static void ForceForeground(IntPtr h) {
        ShowWindow(h, 9);
        int pid;
        int fgT = GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        int me = GetCurrentThreadId();
        if (fgT != me) AttachThreadInput(me, fgT, true);
        BringWindowToTop(h);
        SetForegroundWindow(h);
        if (fgT != me) AttachThreadInput(me, fgT, false);
    }
    public static bool IsForeground(IntPtr h) { return GetForegroundWindow() == h; }
    public static int FocusByTitle(string prefix) {
        int c = 0;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            System.Text.StringBuilder sb = new System.Text.StringBuilder(256);
            GetWindowText(h, sb, 256);
            if (sb.ToString().StartsWith(prefix)) { ForceForeground(h); c++; return false; }
            return true;
        }, IntPtr.Zero);
        return c;
    }
    public static int MinimizeByTitle(string prefix) {
        int c = 0;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            System.Text.StringBuilder sb = new System.Text.StringBuilder(256);
            GetWindowText(h, sb, 256);
            if (IsWindowVisible(h) && sb.ToString().StartsWith(prefix)) { ShowWindow(h, 6); c++; }
            return true;
        }, IntPtr.Zero);
        return c;
    }
}
"@

# Compilar C# cuesta ~0,4 s en cada arranque. Se compila una vez a cache\NOMBRE-<huella>.dll y despues solo se carga.
function Import-Cached([string]$Source, [string]$Name, [string[]]$Refs = @()) {
    $sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Source))).Replace('-', '').Substring(0, 10)
    $dir = Join-Path $Root 'cache'
    $dll = Join-Path $dir "$Name-$sha.dll"
    try {
        if (-not (Test-Path $dll)) {
            New-Item -ItemType Directory -Force $dir | Out-Null
            Get-ChildItem $dir -Filter "$Name-*.dll" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            if ($Refs.Count) { Add-Type -TypeDefinition $Source -OutputAssembly $dll -OutputType Library -ReferencedAssemblies $Refs } else { Add-Type -TypeDefinition $Source -OutputAssembly $dll -OutputType Library }
        }
        Add-Type -Path $dll
    }
    catch {
        if ($Refs.Count) { Add-Type -TypeDefinition $Source -ReferencedAssemblies $Refs } else { Add-Type -TypeDefinition $Source }
    }
}
Import-Cached $HubWinSource 'HubWin'
[HubWin]::SetProcessDPIAware() | Out-Null

# Minimiza la ventana del Hub (la ventana de Edge cuyo titulo es "Sven Coop Hub")
function Hide-HubWindow {
    [HubWin]::MinimizeByTitle('Sven Coop Hub') | Out-Null
}

# Espera a que exista la ventana del juego y le da el foco para que capture el mouse
function Focus-GameWhenReady {
    foreach ($i in 1..40) {
        Start-Sleep -Milliseconds 750
        $p = Get-Process -Name svencoop -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($p -and $p.MainWindowHandle -ne 0) {
            Start-Sleep -Milliseconds 1500
            [HubWin]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [HubWin]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
            [HubWin]::ForceForeground($p.MainWindowHandle)
            return
        }
    }
}

function Get-ScreenSize { @{ w = [HubWin]::GetSystemMetrics(0); h = [HubWin]::GetSystemMetrics(1) } }

# ventana | full (resolucion nativa) | full43 (4:3 con barras negras a los lados)
function Get-ScreenArgs($mode) {
    $s = Get-ScreenSize
    switch ($mode) {
        'window' { return @('-windowed') }
        'full43' { return @('-fullscreen', '-width', [string][int]($s.h * 4 / 3), '-height', [string]$s.h) }
        default { return @('-fullscreen', '-width', [string]$s.w, '-height', [string]$s.h) }
    }
}

function Get-PlayerModels($game) {
    $set = @{}
    foreach ($d in (Get-ChildItem $game -Directory -Filter 'svencoop*' -ErrorAction SilentlyContinue)) {
        $m = Join-Path $d.FullName 'models\player'
        if (Test-Path $m) {
            foreach ($x in (Get-ChildItem $m -Directory)) {
                if (Test-Path (Join-Path $x.FullName ($x.Name + '.mdl'))) { $set[$x.Name] = $x.FullName }
            }
        }
    }
    $set
}

function Get-PlayerCfg($game) {
    $f = Join-Path $game 'svencoop\config.cfg'
    $o = @{ model = ''; top = 0; bottom = 0 }
    if (Test-Path $f) {
        $t = Get-Content $f -Raw
        $m = [regex]::Match($t, '(?m)^model\s+"([^"]*)"'); if ($m.Success) { $o.model = $m.Groups[1].Value }
        $m = [regex]::Match($t, '(?m)^topcolor\s+"(\d+)"'); if ($m.Success) { $o.top = [int]$m.Groups[1].Value }
        $m = [regex]::Match($t, '(?m)^bottomcolor\s+"(\d+)"'); if ($m.Success) { $o.bottom = [int]$m.Groups[1].Value }
    }
    $o
}

$BindBegin = '// >>> Sven Coop Hub (atajo F8)'
$BindEnd = '// <<< Sven Coop Hub F8'
$BindLine = 'bind "F8" "exec hub_cmd.cfg"'

function Test-Bind($game) {
    $f = Join-Path $game 'svencoop\userconfig.cfg'
    (Test-Path $f) -and ((Get-Content $f -Raw) -like "*$BindBegin*")
}

function Set-Bind($game) {
    $f = Join-Path $game 'svencoop\userconfig.cfg'
    $txt = ''; if (Test-Path $f) { $txt = Get-Content $f -Raw }
    if ($txt -notlike "*$BindBegin*") {
        $txt = $txt.TrimEnd() + "`r`n`r`n$BindBegin`r`n$BindLine`r`n$BindEnd`r`n"
        Write-Atomic $f $txt
    }
    Set-Tp $game
    $c = Join-Path $game 'svencoop\hub_cmd.cfg'
    if (-not (Test-Path $c)) { Write-Atomic $c "echo [HUB] sin comandos`r`n" }
}

# Instala /tp (plugin propio) y activa /s /p (plugin Teleport original) en default_plugins.txt
function Test-Tp($game) {
    $f = Join-Path $game 'svencoop\default_plugins.txt'
    (Test-Path (Join-Path $game 'svencoop\scripts\plugins\HubTP.as')) -and (Test-Path $f) -and ((Get-Content $f -Raw) -match '(?m)^\s*"script"\s+"HubTP"')
}

function Set-Tp($game) {
    $dst = Join-Path $game 'svencoop\scripts\plugins\HubTP.as'
    Copy-Item (Join-Path $Root 'plugins\HubTP.as') $dst -Force
    $f = Join-Path $game 'svencoop\default_plugins.txt'
    $bak = $f + '.hubbak'
    if (-not (Test-Path $bak)) { Copy-Item $f $bak }
    $txt = Get-Content $f -Raw
    # descomenta el plugin Teleport original (/s guardar, /p cargar)
    $txt = [regex]::Replace($txt, '(?m)^//(\s*"plugin"\s*\r?\n)//(\s*\{\s*\r?\n)//(\s*"name"\s+"Teleport"\s*\r?\n)//(\s*"script"\s+"Teleport"\s*\r?\n)//(\s*\}\s*\r?\n)', '$1$2$3$4$5')
    if ($txt -notmatch '(?m)^\s*"script"\s+"HubTP"') {
        $block = "`t`"plugin`"`r`n`t{`r`n`t`t`"name`" `"HubTP`"`r`n`t`t`"script`" `"HubTP`"`r`n`t}`r`n"
        $i = $txt.LastIndexOf('}')
        $txt = $txt.Substring(0, $i) + "`r`n" + $block + $txt.Substring($i)
    }
    Write-Atomic $f $txt
}

# Escribe hub_cmd.cfg y pulsa F8 dentro del juego (que ejecuta ese cfg)
function Send-GameCmd($game, $lines) {
    $proc = Get-GameProc
    if (-not $proc) { throw 'Sven Co-op no esta abierto.' }
    $clean = @($lines | ForEach-Object { "$_".Trim() } | Where-Object { $_ -and $_ -notmatch '(?i)^(quit|exit|rcon_password|alias|bind|unbind)\b' })
    if ($clean.Count -eq 0) { throw 'Sin comandos.' }
    if ($clean.Count -gt 60) { throw 'Demasiados comandos.' }
    $hdr = "alias w5 `"wait;wait;wait;wait;wait`"`r`nalias w25 `"w5;w5;w5;w5;w5`"`r`n"
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    Write-Atomic (Join-Path $game 'svencoop\hub_cmd.cfg') ($hdr + ($clean -join "`r`n") + "`r`necho [HUB] cmd $id`r`n")
    $h = $proc.MainWindowHandle
    [HubWin]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [HubWin]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    [HubWin]::ForceForeground($h)
    $t0 = Get-Date
    while (-not [HubWin]::IsForeground($h) -and ((Get-Date) - $t0).TotalMilliseconds -lt 1500) { Start-Sleep -Milliseconds 25 }
    Start-Sleep -Milliseconds 80
    [HubWin]::keybd_event(0x77, 0x42, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 40
    [HubWin]::keybd_event(0x77, 0x42, 2, [UIntPtr]::Zero)
    Log ("cmd $id " + ($clean -join ' | '))
    return $id
}

$script:Page = $null
$script:PageStamp = 0
function Get-Page {
    $f = Join-Path $Web 'index.html'
    $t = (Get-Item $f).LastWriteTimeUtc.Ticks
    if ($script:PageStamp -ne $t) {
        $script:Page = $Utf8.GetBytes((Get-Content $f -Raw -Encoding UTF8).Replace('__TOKEN__', $token))
        $script:PageStamp = $t
    }
    return , $script:Page
}

function Get-InstalledMaps($game) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($d in [IO.Directory]::GetDirectories($game, 'svencoop*')) {
        $m = Join-Path $d 'maps'
        if ([IO.Directory]::Exists($m)) { foreach ($f in [IO.Directory]::GetFiles($m, '*.bsp')) { [void]$set.Add([IO.Path]::GetFileNameWithoutExtension($f)) } }
    }
    return @($set | Sort-Object)
}

function Get-GameProc { Get-Process -Name svencoop -ErrorAction SilentlyContinue | Select-Object -First 1 }

# ---- progreso de arranque (lee el console log del juego; cada paso lo confirma un echo [HUB] del cfg) ----
$script:Launch = $null

function Get-ConLogPath($game) { Join-Path $game ("console-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd')) }

function Read-LogFrom($path, [long]$offset) {
    if (-not (Test-Path $path)) { return '' }
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
        if ($fs.Length -lt $offset) { $offset = 0 }
        $fs.Seek($offset, 'Begin') | Out-Null
        return (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd()
    }
    finally { $fs.Close() }
}

function Get-LogLength($path) { if (Test-Path $path) { return (Get-Item $path).Length } else { return 0 } }

function Test-CmdDone($game, $id) {
    $path = Get-ConLogPath $game
    $off = [math]::Max(0, (Get-LogLength $path) - 200000)
    (Read-LogFrom $path $off).Contains("[HUB] cmd $id")
}

function Get-LaunchProgress($game) {
    $L = $script:Launch
    if (-not $L) { return @{ active = $false } }
    $proc = Get-GameProc
    if ($proc) { $L.seen = $true }
    $elapsed = [int]((Get-Date) - $L.at).TotalSeconds
    $text = Read-LogFrom (Get-ConLogPath $game) $L.offset
    $steps = @()
    $steps += @{ k = 'game'; label = 'Abriendo Sven Co-op'; done = [bool]($proc -and $proc.MainWindowHandle -ne 0) -or $text.Length -gt 0 }
    if ($L.mode -eq 'join') {
        $steps += @{ k = 'connect'; label = 'Conectando con tu amigo'; done = $text.Contains('[HUB] conectando') }
        $steps += @{ k = 'ready'; label = 'Dentro de la partida'; done = ($text -match 'joined the game') }
    }
    else {
        $steps += @{ k = 'map'; label = 'Cargando el mapa'; done = $text.Contains('Host player for this game') }
        $steps += @{ k = 'cheats'; label = 'Trucos (sv_cheats)'; done = $text.Contains('[HUB] ok cheats') }
        $steps += @{ k = 'respawn'; label = 'Reaparicion (mp_respawndelay)'; done = $text.Contains('[HUB] ok respawn') }
        $steps += @{ k = 'survival'; label = 'Supervivencia'; done = $text.Contains('[HUB] ok survival') }
        $steps += @{ k = 'classic'; label = 'Modo clasico'; done = $text.Contains('[HUB] ok classic') }
        if ($L.hasExtra) { $steps += @{ k = 'extra'; label = 'Tus comandos extra'; done = $text.Contains('[HUB] ok extra') } }
        $steps += @{ k = 'ready'; label = 'Sala lista'; done = $text.Contains('[HUB] sala lista') }
    }
    $done = @($steps | Where-Object { -not $_.done }).Count -eq 0
    if ($L.mode -eq 'join' -and -not $done -and $elapsed -gt 60 -and $proc) { $done = $true }
    $err = $null
    if (-not $proc -and $L.seen -and -not $done) { $err = 'El juego se cerro antes de terminar de cargar.' }
    elseif (-not $proc -and -not $L.seen -and $elapsed -gt 25) { $err = 'El juego no abrio. Revisa que Steam este abierto.' }
    if ($done -and -not $L.handled) {
        $L.handled = $true
        if ($L.minimize) { Hide-HubWindow }
        if ($proc) { Start-Sleep -Milliseconds 700; [HubWin]::ForceForeground($proc.MainWindowHandle) }
    }
    return @{ active = $true; steps = $steps; done = $done; error = $err; elapsed = $elapsed }
}

function Start-Game($game, $p) {
    if (-not $game) { throw 'No encuentro Sven Co-op. Instalalo desde Steam.' }
    if (-not (Test-Path (Join-Path $game 'svencoop.exe'))) { throw 'No encuentro svencoop.exe en la carpeta del juego.' }
    if (-not (Get-Process -Name steam -ErrorAction SilentlyContinue)) { throw 'Steam esta cerrado. Abre Steam y vuelve a intentar.' }
    if (Get-GameProc) { throw 'Sven Co-op ya esta abierto. Cierralo primero (boton Cerrar juego).' }
    $sv = Join-Path $game 'svencoop'
    $argList = @('-console', '-condebug')
    $mode = "$($p.screen)"; if (-not $mode) { if ($p.windowed) { $mode = 'window' } else { $mode = 'full' } }
    $argList += (Get-ScreenArgs $mode)
    $extra = ''
    if ($p.mode -eq 'join') {
        if ($p.joinId -notmatch '^STEAM_[0-5]:[01]:\d{1,12}$') { throw 'STEAM_ID invalido.' }
        Set-Bind $game
        $cfg = "// generado por Sven Coop Hub`r`n$BindLine`r`necho [HUB] conectando`r`nconnect $($p.joinId)`r`n"
        Write-Atomic (Join-Path $sv 'hub_join.cfg') $cfg
        $argList += @('+exec', 'hub_join.cfg')
    }
    else {
        if ($p.map -notmatch '^[A-Za-z0-9_]+$') { throw 'Mapa invalido.' }
        if ((Get-InstalledMaps $game) -notcontains $p.map) { throw "El mapa $($p.map) no esta instalado en tu juego." }
        $max = [math]::Min(32, [math]::Max(2, [int]$p.maxplayers))
        $resp = [math]::Min(60, [math]::Max(0, [int]$p.respawn))
        $surv = [int]$p.survival; if ($surv -lt -1 -or $surv -gt 1) { $surv = -1 }
        $cheats = 0; if ($p.cheats) { $cheats = 1 }
        $classic = 0; if ($p.classic) { $classic = 1 }
        if ($p.extra) { $extra = (($p.extra -split "[\r\n]+" | Where-Object { $_.Trim() -and $_ -notmatch '(?i)^\s*(quit|exit|rcon_password)\b' }) -join "`r`n") }
        if ($extra.Length -gt 2000) { throw 'Comandos extra demasiado largos.' }
        Set-Bind $game
        $skin = ''
        if ("$($p.model)" -match '^[A-Za-z0-9_\-]+$') { $skin += "model $($p.model)`r`n" }
        if ($null -ne $p.topcolor -and $null -ne $p.bottomcolor) {
            $skin += "topcolor $([math]::Min(255,[math]::Max(0,[int]$p.topcolor)))`r`nbottomcolor $([math]::Min(255,[math]::Max(0,[int]$p.bottomcolor)))`r`n"
        }
        $extraMark = ''
        if ($extra) { $extraMark = 'echo [HUB] ok extra' }
        $post = @"
sv_cheats $cheats
echo [HUB] ok cheats
mp_respawndelay $resp
echo [HUB] ok respawn
toggle_survival_mode $surv
echo [HUB] ok survival
toggle_classic_mode $classic
echo [HUB] ok classic
$extra
$extraMark
"@
        $cfg = @"
// generado por Sven Coop Hub
alias w5 "wait;wait;wait;wait;wait"
alias w25 "w5;w5;w5;w5;w5"
alias w125 "w25;w25;w25;w25;w25"
alias w625 "w125;w125;w125;w125;w125"
$BindLine
$skin
sv_lan 0
sv_cheats $cheats
mp_respawndelay $resp
maxplayers $max
map $($p.map)
w625
echo [HUB] mapa listo
$post
sv_lan 0
echo [HUB] sala lista
"@
        Write-Atomic (Join-Path $sv 'hub_host.cfg') $cfg
        $argList += @('+exec', 'hub_host.cfg')
    }
    $script:Launch = @{
        at = Get-Date; mode = "$($p.mode)"; offset = (Get-LogLength (Get-ConLogPath $game))
        hasExtra = [bool]($extra); minimize = ($p.minimize -ne $false); seen = $false; handled = $false
    }
    Start-Process -FilePath (Join-Path $game 'svencoop.exe') -ArgumentList $argList -WorkingDirectory $game | Out-Null
    Log ("launch " + ($argList -join ' '))
}

function Send($ctx, $body, $type = 'application/json; charset=utf-8', $status = 200) {
    if ($body -isnot [byte[]]) {
        if ($body -isnot [string]) { $body = $body | ConvertTo-Json -Depth 8 -Compress }
        $body = $Utf8.GetBytes($body)
    }
    $ctx.Response.StatusCode = $status
    $ctx.Response.ContentType = $type
    $ctx.Response.Headers.Add('Cache-Control', 'no-store')
    $ctx.Response.ContentLength64 = $body.Length
    $ctx.Response.OutputStream.Write($body, 0, $body.Length)
    $ctx.Response.OutputStream.Close()
}

function Open-Window($url) {
    if ($NoBrowser) { return $null }
    $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $edge) { $edge = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction SilentlyContinue).'(default)' }
    if ($edge) {
        $prof = Join-Path $Root '.browser-profile'
        return Start-Process -FilePath $edge -ArgumentList @("--app=$url", '--start-maximized', "--user-data-dir=`"$prof`"", '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--disable-sync', '--disable-features=Translate') -PassThru
    }
    Start-Process $url | Out-Null
    return $null
}

. (Join-Path $Root 'lib.ps1')
. (Join-Path $Root 'update.ps1')

# ---- instancia unica: si ya esta corriendo, solo abre otra ventana ----
if (Test-Path $RunFile) {
    try {
        $r = Get-Content $RunFile -Raw | ConvertFrom-Json
        if ((Get-Process -Id $r.pid -ErrorAction SilentlyContinue).ProcessName -match 'powershell') { Open-Window "http://127.0.0.1:$($r.port)/?t=$($r.token)" | Out-Null; exit 0 }
    } catch {}
}

$script:Relaunch = $false
$hubArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"", '-NoUpdate')
if ($NoBrowser) { $hubArgs += '-NoBrowser' }

# la version nueva instalada no llego a arrancar: volver a la que funcionaba
$pendingFile = Join-Path $Root 'update.pending'
if (Test-Path $pendingFile) {
    $pend = (Get-Content $pendingFile -Raw).Trim() -split ','
    if ($pend.Count -ge 2 -and [int]$pend[1] -ge 1) {
        # ya lo intento una vez y no llego a confirmar el arranque
        Log "la v$($pend[0]) no llego a arrancar: se vuelve a la anterior"
        Restore-Previous
        Start-PSHidden $hubArgs | Out-Null
        exit 0
    }
    [IO.File]::WriteAllText($pendingFile, "$($pend[0]),1")   # primer arranque de la version nueva
}
# auto-actualizacion al abrir (firmada y con respaldo); si no hay internet, sigue con lo que hay
$checkedFile = Join-Path $Root 'update.checked'
$checkedRecently = (Test-Path $checkedFile) -and (((Get-Date).ToUniversalTime() - (Get-Item $checkedFile).LastWriteTimeUtc).TotalMinutes -lt 30)
if (-not $NoUpdate -and -not $checkedRecently) {
    $up = Invoke-SelfUpdate $true
    if ($up.status -in 'al-dia', 'omitida', 'disabled') { [IO.File]::WriteAllText($checkedFile, '') }
    if ($up.status -eq 'actualizado') {
        # se abre la version nueva y se vigila: si no llega a confirmar su arranque, se vuelve a la anterior
        $child = Start-PSHidden $hubArgs
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Milliseconds 500
            if (-not (Test-Path $pendingFile)) { break }
            if ($child.HasExited) { break }
        }
        if (Test-Path $pendingFile) {
            Log 'la version nueva no arranco: se vuelve a la anterior'
            Restore-Previous
            Start-PSHidden $hubArgs | Out-Null
        }
        exit 0
    }
}

$game = Find-Game
$token = [guid]::NewGuid().ToString('N')
$listener = $null; $port = 0
foreach ($try in 1..30) {
    $port = Get-Random -Minimum 41000 -Maximum 49000
    try { $listener = New-Object System.Net.HttpListener; $listener.Prefixes.Add("http://127.0.0.1:$port/"); $listener.Start(); break } catch { $listener = $null }
}
if (-not $listener) { throw 'No pude abrir un puerto local.' }
@{ pid = $PID; port = $port; token = $token } | ConvertTo-Json | Set-Content $RunFile -Encoding ASCII
Remove-Item (Join-Path $Root 'update.pending') -Force -ErrorAction SilentlyContinue
if ($game) {
    $s0 = Read-Settings
    $optedOut = ($s0 -and $null -ne $s0.autoRepair -and -not $s0.autoRepair)
    if (-not $optedOut -and (-not (Test-Bind $game) -or -not (Test-Tp $game))) {
        try { Repair-All $game; Log 'reparado automaticamente: faltaba el atajo F8 o el plugin /tp' } catch { Log "autorreparacion fallo: $($_.Exception.Message)" }
    }
}
$user = Get-SteamUser
$mapsCache = $null
$lastPing = Get-Date
$edgeProc = Open-Window "http://127.0.0.1:$port/?t=$token"
$script:WantTab = ''
$headless = $null
Update-Overlay $port $token
# mientras Edge arranca (~1 s) se calientan las cachés: la primera peticion de la pagina ya las encuentra listas
if ($game) {
    $mapsCache = Get-InstalledMaps $game
    [void](Get-ModelInfoCached $game)
    Start-ThumbWarmer $game
}
Log "hub en puerto $port, juego: $game"

try {
    while ($listener.IsListening) {
        $task = $listener.GetContextAsync()
        while (-not $task.Wait(1000)) {
            if ($edgeProc) {
                if ($edgeProc.HasExited) {
                    # con el boton flotante activo el Hub sigue en segundo plano para poder reabrir la ventana
                    if (Test-OverlayOn) { $edgeProc = $null; $headless = Get-Date } else { return }
                }
            }
            elseif ($headless) {
                if (Get-GameProc) { $headless = Get-Date }
                elseif (((Get-Date) - $headless).TotalMinutes -gt 5) { return }
            }
            elseif (((Get-Date) - $lastPing).TotalSeconds -gt 180) { return }
        }
        $ctx = $task.Result
        try {
            $path = $ctx.Request.Url.AbsolutePath
            $authed = ($ctx.Request.Headers['X-Hub'] -eq $token)
            if ($path -eq '/' -or $path -eq '/index.html') {
                Send $ctx (Get-Page) 'text/html; charset=utf-8'
                continue
            }
            if ($path -eq '/api/modelimg' -and $ctx.Request.QueryString['t'] -eq $token) {
                $n = "$($ctx.Request.QueryString['n'])"
                $mi = @(Get-ModelInfoCached $game | Where-Object { $_.name -eq $n }) | Select-Object -First 1
                if ((Test-SkinName $n) -and $mi) {
                    $img = Join-Path $mi.dir ($n + '.bmp')
                    if (Test-Path $img) { Send $ctx (Get-Thumb $img) 'image/png'; continue }
                }
                Send $ctx '{"error":"404"}' 'application/json' 404; continue
            }
            if (-not $authed) { Send $ctx '{"error":"no autorizado"}' 'application/json' 403; continue }
            if (-not $game -and $path -in '/api/launch', '/api/cmd', '/api/bind', '/api/autolan', '/api/repair', '/api/undo', '/api/skinadd', '/api/skindel', '/api/modupload', '/api/modinstall', '/api/mods', '/api/moddel', '/api/modcancel', '/api/openurl') {
                Send $ctx @{ ok = $false; error = 'No encuentro Sven Co-op. Instalalo desde Steam.' }; continue
            }
            switch ($path) {
                '/api/ping' {
                    $lastPing = Get-Date
                    $wantTab = $script:WantTab; $script:WantTab = ''
                    Send $ctx @{ running = [bool](Get-GameProc); steam = [bool](Get-Process steam -ErrorAction SilentlyContinue); tab = $wantTab; overlay = (Test-OverlayOn) }
                }
                '/api/openhub' {
                    $p = (Read-Body $ctx) | ConvertFrom-Json
                    $script:WantTab = "$($p.tab)"
                    $n = [HubWin]::FocusByTitle('Sven Coop Hub'); Log "openhub tab=$($script:WantTab) ventanas=$n"
                    if ($n -eq 0 -and -not $NoBrowser) { $edgeProc = Open-Window "http://127.0.0.1:$port/?t=$token"; $headless = $null }
                    Send $ctx @{ ok = $true }
                }
                '/api/overlay' {
                    $p = (Read-Body $ctx) | ConvertFrom-Json
                    Set-Setting 'overlay' ([bool]$p.enabled)
                    Update-Overlay $port $token
                    Send $ctx @{ ok = $true; overlay = [bool]$p.enabled; running = (Test-OverlayOn) }
                }
                '/api/tpcard' {
                    $p = (Read-Body $ctx) | ConvertFrom-Json
                    Set-Setting 'tpcard' ([bool]$p.enabled)
                    Update-Overlay $port $token
                    Send $ctx @{ ok = $true; tpcard = [bool]$p.enabled }
                }
                '/api/update' {
                    $p = (Read-Body $ctx) | ConvertFrom-Json
                    $res = Invoke-SelfUpdate ([bool]$p.apply)
                    Send $ctx $res
                    if ($res.status -eq 'actualizado') { $script:Relaunch = $true; return }
                }
                '/api/skinadd' {
                    try { $bytes = Read-BodyBytes $ctx; $done = @(Add-SkinZip $game $bytes); Send $ctx @{ ok = $true; installed = $done } }
                    catch { Send $ctx @{ ok = $false; error = $_.Exception.Message } }
                }
                '/api/skindel' {
                    $p = (Read-Body $ctx) | ConvertFrom-Json
                    try { Remove-Skin $game "$($p.name)"; Send $ctx @{ ok = $true } }
                    catch { Send $ctx @{ ok = $false; error = $_.Exception.Message } }
                }
                '/api/modupload' {
                    try { Send $ctx (@{ ok = $true } + (Save-PendingMod $game $ctx "$($ctx.Request.QueryString['file'])")) }
                    catch { Send $ctx @{ ok = $false; error = $_.Exception.Message } }
                }
                '/api/modinstall' {
                    $p = (Read-Body $ctx) | ConvertFrom-Json
                    try { Send $ctx (@{ ok = $true } + (Install-PendingMod $game "$($p.id)")) }
                    catch { Send $ctx @{ ok = $false; error = $_.Exception.Message } }
                }
                '/api/modcancel' { $p = (Read-Body $ctx) | ConvertFrom-Json; Remove-PendingMod "$($p.id)"; Send $ctx @{ ok = $true } }
                '/api/mods' { Send $ctx @{ mods = @(Get-InstalledMods $game); essentials = @(Get-Essentials $game) } }
                '/api/moddel' {
                    $p = (Read-Body $ctx) | ConvertFrom-Json
                    try { Remove-Mod $game "$($p.id)"; Send $ctx @{ ok = $true } }
                    catch { Send $ctx @{ ok = $false; error = $_.Exception.Message } }
                }
                '/api/openurl' {
                    $p = (Read-Body $ctx) | ConvertFrom-Json
                    try { Open-AllowedUrl "$($p.url)"; Send $ctx @{ ok = $true } }
                    catch { Send $ctx @{ ok = $false; error = $_.Exception.Message } }
                }
                '/api/diag' { Send $ctx @{ text = (Get-Diag $game $user) } }
                '/api/health' { Send $ctx @{ items = @(Get-Health $game $user) } }
                '/api/repair' {
                    try { Repair-All $game; Set-Setting 'autoRepair' $true; Send $ctx @{ ok = $true; items = @(Get-Health $game $user) } }
                    catch { Send $ctx @{ ok = $false; error = $_.Exception.Message } }
                }
                '/api/undo' {
                    try { Undo-All $game; Set-Setting 'autoRepair' $false; Send $ctx @{ ok = $true; items = @(Get-Health $game $user) } }
                    catch { Send $ctx @{ ok = $false; error = $_.Exception.Message } }
                }
                '/api/steam' { Start-Process 'steam://open/main'; Send $ctx @{ ok = $true } }
                '/api/state' {
                    if (-not $mapsCache -and $game) { $mapsCache = Get-InstalledMaps $game }
                    Send $ctx @{
                        gamePath = $game; steamId = $user.steamId; steamName = $user.name
                        steamRunning = [bool](Get-Process steam -ErrorAction SilentlyContinue)
                        running = [bool](Get-GameProc); maps = $mapsCache
                        autoLan = [bool]($game -and (Test-AutoLan $game))
                        bindReady = [bool]($game -and (Test-Bind $game))
                        tpReady = [bool]($game -and (Test-Tp $game))
                        version = $Version
                        overlay = (Test-OverlayOn)
                        changelog = @(Get-Changelog)
                        screen = (Get-ScreenSize)
                        player = (Get-PlayerCfg $game)
                        models = @(Get-ModelInfoCached $game | ForEach-Object { @{ name = $_.name; custom = $_.custom; img = $_.img } })
                        settings = (Read-Settings)
                    }
                }
                '/api/save' {
                    $body = (Read-Body $ctx)
                    try { $null = $body | ConvertFrom-Json } catch { throw 'Ajustes invalidos (no son JSON).' }
                    Write-Atomic $SettingsFile $body
                    Send $ctx @{ ok = $true }
                }
                '/api/autolan' {
                    $p = (Read-Body $ctx) | ConvertFrom-Json
                    Set-AutoLan $game ([bool]$p.enabled)
                    Send $ctx @{ ok = $true; autoLan = (Test-AutoLan $game) }
                }
                '/api/launch' {
                    $p = (Read-Body $ctx) | ConvertFrom-Json
                    try { Start-Game $game $p; Send $ctx @{ ok = $true } }
                    catch { Send $ctx @{ ok = $false; error = $_.Exception.Message } }
                }
                '/api/progress' { Send $ctx (Get-LaunchProgress $game) }
                '/api/cmdstatus' { Send $ctx @{ done = [bool](Test-CmdDone $game "$($ctx.Request.QueryString['id'])") } }
                '/api/bind' { Set-Bind $game; Send $ctx @{ ok = $true; bindReady = (Test-Bind $game) } }
                '/api/cmd' {
                    $p = (Read-Body $ctx) | ConvertFrom-Json
                    try { $cid = Send-GameCmd $game @($p.cmds); Send $ctx @{ ok = $true; id = $cid } }
                    catch { Send $ctx @{ ok = $false; error = $_.Exception.Message } }
                }
                '/api/stop' { Get-Process -Name svencoop -ErrorAction SilentlyContinue | Stop-Process -Force; Send $ctx @{ ok = $true } }
                '/api/quit' { Send $ctx @{ ok = $true }; return }
                default { Send $ctx '{"error":"404"}' 'application/json' 404 }
            }
        }
        catch { Log ("error: " + $_.Exception.Message); try { Send $ctx @{ ok = $false; error = $_.Exception.Message } 'application/json' 500 } catch {} }
    }
}
finally {
    Stop-Overlay
    try { $listener.Stop() } catch {}
    Remove-Item $RunFile -ErrorAction SilentlyContinue
    if ($script:Relaunch) { Start-PSHidden $hubArgs | Out-Null }
}
