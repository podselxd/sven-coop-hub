# lib.ps1 - mantenimiento a prueba de errores (poka-yoke)
# Se carga desde hub.ps1 (dot-source): usa $Utf8, $BindBegin/$BindEnd, $MarkBegin y las funciones Set-*/Test-* de hub.ps1.

# Escritura atomica: se escribe a un temporal y se reemplaza. Un corte de luz o un cierre a medias no deja un archivo roto.
function Write-Atomic([string]$Path, [string]$Text) {
    $tmp = "$Path.hubtmp"
    [IO.File]::WriteAllText($tmp, $Text, $Utf8)
    if (Test-Path $Path) {
        $old = "$Path.hubold"
        [IO.File]::Replace($tmp, $Path, $old)
        Remove-Item $old -Force -ErrorAction SilentlyContinue
    }
    else { [IO.File]::Move($tmp, $Path) }
}

# Lee el cuerpo de una peticion con tope de tamano (nadie manda 50 MB al Hub por error)
function Read-Body($ctx, [int]$Max = 65536) {
    $sr = New-Object IO.StreamReader($ctx.Request.InputStream, $Utf8)
    $buf = New-Object char[] ($Max + 1)
    $n = $sr.Read($buf, 0, $Max + 1)
    if ($n -gt $Max) { throw 'Peticion demasiado grande.' }
    return [string]::new($buf, 0, $n)
}

# Errores de compilacion de HubTP.as en la sesion actual del juego (solo lo posterior al ultimo arranque del log)
function Get-PluginErrors($game) {
    $dir = Join-Path $game 'svencoop\logs\Angelscript'
    $f = Get-ChildItem $dir -Filter 'AS_server_*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $f) { return @() }
    $lines = @(Get-Content $f.FullName -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) { return @() }
    $start = 0
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match 'Server started logging Angelscript') { $start = $i } }
    @($lines[$start..($lines.Count - 1)] | Where-Object { $_ -match 'ERROR' -and $_ -match 'HubTP' })
}

function New-Check($id, $level, $label, $detail) { @{ id = $id; level = $level; label = $label; detail = $detail } }

# level: ok | warn | bad
function Get-Health($game, $user) {
    $items = @()
    if ($game) { $items += New-Check 'game' 'ok' 'Sven Co-op encontrado' $game }
    else { return @(New-Check 'game' 'bad' 'No encuentro Sven Co-op' 'Instala el juego desde Steam y vuelve a abrir el Hub.') }
    if (Get-Process -Name steam -ErrorAction SilentlyContinue) { $items += New-Check 'steam' 'ok' 'Steam abierto' '' }
    else { $items += New-Check 'steam' 'bad' 'Steam esta cerrado' 'Abre Steam para poder jugar.' }
    if ($user) { $items += New-Check 'user' 'ok' "Cuenta detectada: $($user.name)" $user.steamId }
    else { $items += New-Check 'user' 'warn' 'No detecte tu cuenta de Steam' 'Inicia sesion en Steam.' }
    if (Test-Bind $game) { $items += New-Check 'bind' 'ok' 'Atajo F8 para comandos' 'userconfig.cfg' }
    else { $items += New-Check 'bind' 'bad' 'Falta el atajo F8' 'Sin el, la pestana Comandos no puede mandar nada. Pulsa Reparar todo.' }
    if (Test-Tp $game) { $items += New-Check 'plugin' 'ok' 'Plugin /tp instalado' 'HubTP.as' }
    else { $items += New-Check 'plugin' 'bad' 'Falta el plugin /tp' 'Pulsa Reparar todo.' }
    $errs = @(Get-PluginErrors $game)
    if ($errs.Count -eq 0) { $items += New-Check 'compile' 'ok' 'El plugin /tp carga sin errores' 'Segun el log de AngelScript' }
    else { $items += New-Check 'compile' 'bad' 'El plugin /tp tiene errores de compilacion' $errs[0] }
    if (Test-AutoLan $game) { $items += New-Check 'lan' 'ok' 'sv_lan 0 automatico en todo multijugador' 'listenserver.cfg' }
    else { $items += New-Check 'lan' 'warn' 'sv_lan 0 automatico desactivado' 'Actívalo en Crear partida > Reglas si quieres.' }
    return $items
}

# Reinstala lo que el Hub necesita. Es idempotente: se puede pulsar las veces que sea.
function Repair-All($game) {
    Set-Bind $game
    Set-Tp $game
    Get-ChildItem (Join-Path $game 'svencoop') -Filter '*.hubtmp' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

# Deja el juego como estaba antes de usar el Hub
function Undo-All($game) {
    $sv = Join-Path $game 'svencoop'
    $uc = Join-Path $sv 'userconfig.cfg'
    if (Test-Path $uc) {
        $t = Get-Content $uc -Raw
        $t = [regex]::Replace($t, '(?s)\r?\n?' + [regex]::Escape($BindBegin) + '.*?' + [regex]::Escape($BindEnd) + '\r?\n?', "`r`n")
        Write-Atomic $uc ($t.TrimEnd() + "`r`n")
    }
    Set-AutoLan $game $false
    $dp = Join-Path $sv 'default_plugins.txt'
    if (Test-Path ($dp + '.hubbak')) { Copy-Item ($dp + '.hubbak') $dp -Force }
    elseif (Test-Path $dp) {
        $t = Get-Content $dp -Raw
        $t = [regex]::Replace($t, '(?s)\s*"plugin"\s*\{[^{}]*"script"\s+"HubTP"[^{}]*\}', '')
        Write-Atomic $dp $t
    }
    foreach ($f in 'scripts\plugins\HubTP.as', 'hub_cmd.cfg', 'hub_host.cfg', 'hub_join.cfg') {
        Remove-Item (Join-Path $sv $f) -Force -ErrorAction SilentlyContinue
    }
}

# Texto para pegar en un chat cuando algo falla: version, salud y ultimas lineas de los logs
function Get-Diag($game, $user) {
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add("Sven Coop Hub v$Version")
    $L.Add("Fecha: $(Get-Date -Format s)")
    $L.Add("Windows: $([Environment]::OSVersion.VersionString) | PowerShell $($PSVersionTable.PSVersion)")
    $steam = 'cerrado'; if (Get-Process -Name steam -ErrorAction SilentlyContinue) { $steam = 'abierto' }
    $run = 'cerrado'; if (Get-GameProc) { $run = 'abierto' }
    $L.Add("Juego: $game | Steam: $steam | Sven Co-op: $run")
    if ($user) { $L.Add("Cuenta: $($user.name) $($user.steamId)") }
    $L.Add('--- Salud')
    foreach ($i in (Get-Health $game $user)) { $L.Add(("[{0}] {1} {2}" -f $i.level, $i.label, $i.detail).Trim()) }
    $L.Add('--- hub.log (ultimas 25 lineas)')
    if (Test-Path $LogFile) { foreach ($x in (Get-Content $LogFile -Tail 25)) { $L.Add($x) } }
    if ($game) {
        $con = Get-ConLogPath $game
        if (Test-Path $con) {
            $L.Add('--- consola del juego (ultimas 20 lineas)')
            foreach ($x in (Get-Content $con -Tail 20 -ErrorAction SilentlyContinue)) { $L.Add($x) }
        }
    }
    return ($L -join "`r`n")
}
