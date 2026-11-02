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
    else { return @(New-Check 'game' 'bad' 'No encuentro Sven Co-op' 'Instálalo desde Steam.') }
    if (Get-Process -Name steam -ErrorAction SilentlyContinue) { $items += New-Check 'steam' 'ok' 'Steam abierto' '' }
    else { $items += New-Check 'steam' 'bad' 'Steam esta cerrado' '' }
    if ($user) { $items += New-Check 'user' 'ok' "Cuenta detectada: $($user.name)" $user.steamId }
    else { $items += New-Check 'user' 'warn' 'No detecte tu cuenta de Steam' '' }
    if (Test-Bind $game) { $items += New-Check 'bind' 'ok' 'Atajo F8 para comandos' 'userconfig.cfg' }
    else { $items += New-Check 'bind' 'bad' 'Falta el atajo F8' '' }
    if (Test-Tp $game) { $items += New-Check 'plugin' 'ok' 'Plugin /tp instalado' 'HubTP.as' }
    else { $items += New-Check 'plugin' 'bad' 'Falta el plugin /tp' '' }
    $errs = @(Get-PluginErrors $game)
    if ($errs.Count -eq 0) { $items += New-Check 'compile' 'ok' 'El plugin /tp carga sin errores' '' }
    else { $items += New-Check 'compile' 'bad' 'El plugin /tp tiene errores de compilacion' $errs[0] }
    if (Test-AutoLan $game) { $items += New-Check 'lan' 'ok' 'sv_lan 0 automatico en todo multijugador' 'listenserver.cfg' }
    else { $items += New-Check 'lan' 'warn' 'sv_lan 0 automatico desactivado' '' }
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


# ================= skins =================
# Solo se pueden borrar las skins propias (svencoop_addon / svencoop_downloads); las del juego solo se ocultan desde la interfaz.
$script:ModelCache = $null
$script:ModelCacheAt = [datetime]::MinValue

function Get-ModelInfo($game) {
    $list = @{}
    foreach ($d in [IO.Directory]::GetDirectories($game, 'svencoop*')) {
        $root = Join-Path $d 'models\player'
        if (-not [IO.Directory]::Exists($root)) { continue }
        $dn = [IO.Path]::GetFileName($d)
        $custom = ($dn -eq 'svencoop_addon' -or $dn -eq 'svencoop_downloads')
        foreach ($m in [IO.Directory]::GetDirectories($root)) {
            $name = [IO.Path]::GetFileName($m)
            if (-not [IO.File]::Exists("$m\$name.mdl")) { continue }
            # lo que trae el juego manda sobre una copia propia con el mismo nombre
            if ($list.ContainsKey($name) -and -not $list[$name].custom) { continue }
            $list[$name] = @{ name = $name; custom = $custom; dir = $m; img = [IO.File]::Exists("$m\$name.bmp") }
        }
    }
    return @($list.Values | Sort-Object { $_.name })
}

# La lista se guarda 60 s (o hasta que se agregue/borre una skin): abrir el Hub y pedir 120 miniaturas ya no recorre el disco cada vez
function Get-ModelInfoCached($game) {
    if ($null -eq $script:ModelCache -or ((Get-Date) - $script:ModelCacheAt).TotalSeconds -gt 60) {
        $script:ModelCache = Get-ModelInfo $game
        $script:ModelCacheAt = Get-Date
    }
    return $script:ModelCache
}

function Reset-ModelCache { $script:ModelCache = $null }

# nombres de carpeta seguros: sin barras, sin '..' (hay skins reales como T&F_Kuro)
function Test-SkinName($n) { ("$n" -match '^[A-Za-z0-9_\-&]{1,60}$') -and ("$n" -notmatch '\.\.') }

function Install-SkinFiles($game, [string]$skin, $files) {
    if (-not (Test-SkinName $skin)) { throw "Nombre de skin no valido: $skin" }
    $found = @(Get-ModelInfo $game | Where-Object { $_.name -eq $skin })
    if ($found.Count -gt 0) {
        if ($found[0].custom) { throw "La skin $skin ya existe: eliminala primero." }
        throw "$skin ya viene con el juego."
    }
    if (-not ($files.Keys | Where-Object { $_ -ieq "$skin.mdl" })) { throw "Falta $skin.mdl" }
    # un modelo de Half-Life empieza por la marca IDST: asi no se instala basura renombrada a .mdl
    $mdlKey = $files.Keys | Where-Object { $_ -ieq "$skin.mdl" } | Select-Object -First 1
    $head = $files[$mdlKey]
    if ($head.Length -lt 8 -or [Text.Encoding]::ASCII.GetString($head, 0, 4) -ne 'IDST') { throw "$skin.mdl no parece un modelo de Half-Life." }
    $dir = Join-Path $game "svencoop_addon\models\player\$skin"
    New-Item -ItemType Directory -Force $dir | Out-Null
    try { foreach ($k in $files.Keys) { [IO.File]::WriteAllBytes((Join-Path $dir $k), $files[$k]) } }
    catch { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue; throw }
}

# Instala las skins de un .zip (carpeta/nombre.mdl + nombre.bmp). Valida rutas y tamanos antes de escribir nada.
function Add-SkinZip($game, [byte[]]$bytes) {
    Add-Type -AssemblyName System.IO.Compression
    $ms = New-Object IO.MemoryStream(, $bytes)
    try { $zip = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Read) } catch { throw 'No es un .zip valido.' }
    try {
        if ($zip.Entries.Count -gt 400) { throw 'El zip tiene demasiados archivos.' }
        $total = 0; $groups = @{}
        foreach ($e in $zip.Entries) {
            if (-not $e.Name) { continue }
            if ($e.FullName -match '(^|[\\/])\.\.([\\/]|$)' -or $e.FullName -match '^[A-Za-z]:' -or $e.FullName.StartsWith('/') -or $e.FullName.StartsWith('\')) { throw 'El zip tiene rutas no permitidas.' }
            if ($e.Name -notmatch '^[A-Za-z0-9_\-&]+\.(mdl|bmp|txt)$') { continue }
            $total += $e.Length
            if ($total -gt 60MB) { throw 'El zip es demasiado grande (max 60 MB).' }
            $dir = [IO.Path]::GetDirectoryName($e.FullName.Replace('/', '\'))
            if (-not $groups.ContainsKey($dir)) { $groups[$dir] = @{} }
            $buf = New-Object IO.MemoryStream; $st = $e.Open(); $st.CopyTo($buf); $st.Close()
            $groups[$dir][$e.Name] = $buf.ToArray()
        }
        $installed = @()
        foreach ($dir in @($groups.Keys)) {
            $files = $groups[$dir]
            $stems = @($files.Keys | Where-Object { $_ -like '*.mdl' } | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) })
            foreach ($stem in $stems) {
                # nombreT.mdl es la textura de nombre.mdl, no otra skin
                if ($stem -match '[tT]$' -and ($stems | Where-Object { $_ -ieq $stem.Substring(0, $stem.Length - 1) })) { continue }
                $pick = @{}
                foreach ($k in $files.Keys) {
                    $b = [IO.Path]::GetFileNameWithoutExtension($k)
                    if ($b -ieq $stem -or $b -ieq ($stem + 't')) { $pick[$k] = $files[$k] }
                }
                Install-SkinFiles $game $stem $pick
                $installed += $stem
            }
        }
        if ($installed.Count -eq 0) { throw 'No encontre ninguna skin (.mdl) en el zip.' }
        Reset-ModelCache
        return $installed
    }
    finally { $zip.Dispose() }
}

function Remove-Skin($game, [string]$name) {
    if (-not (Test-SkinName $name)) { throw 'Nombre no valido.' }
    $m = Get-ModelInfo $game | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if (-not $m) { throw 'Esa skin no existe.' }
    if (-not $m.custom) { throw 'Esa skin viene con el juego: no se puede borrar (puedes ocultarla).' }
    $full = [IO.Path]::GetFullPath($m.dir)
    $ok = $false
    foreach ($r in 'svencoop_addon', 'svencoop_downloads') {
        $root = [IO.Path]::GetFullPath((Join-Path $game "$r\models\player")) + '\'
        if ($full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $ok = $true }
    }
    if (-not $ok) { throw 'Ruta no permitida.' }
    Add-Type -AssemblyName Microsoft.VisualBasic
    # a la Papelera de reciclaje: se puede recuperar
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($full, 'OnlyErrorDialogs', 'SendToRecycleBin')
    Reset-ModelCache
}

function Read-BodyBytes($ctx, [long]$Max = 62914560) {
    if ($ctx.Request.ContentLength64 -gt $Max) { throw 'El archivo es demasiado grande.' }
    $ms = New-Object IO.MemoryStream
    $ctx.Request.InputStream.CopyTo($ms)
    if ($ms.Length -gt $Max) { throw 'El archivo es demasiado grande.' }
    return , $ms.ToArray()
}

# Miniaturas: los .bmp de las skins son de 8 bits con paleta y el navegador a veces los pinta negros.
# Se convierten a PNG opaco UNA vez y se guardan en disco (cache\thumbs): abrir Skins despues es instantaneo.
$script:ThumbCache = @{}
function Get-Thumb([string]$path) {
    $stamp = (Get-Item $path).LastWriteTimeUtc.Ticks
    $key = "$path|$stamp"
    if ($script:ThumbCache.ContainsKey($key)) { return , $script:ThumbCache[$key] }
    $sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($key))).Replace('-', '').Substring(0, 16)
    $dir = Join-Path $Root 'cache\thumbs'
    $png = Join-Path $dir "$sha.png"
    if (-not (Test-Path $png)) {
        Add-Type -AssemblyName System.Drawing
        New-Item -ItemType Directory -Force $dir | Out-Null
        $src = New-Object Drawing.Bitmap $path
        try {
            $dst = New-Object Drawing.Bitmap($src.Width, $src.Height, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
            $g = [Drawing.Graphics]::FromImage($dst)
            $g.DrawImage($src, 0, 0, $src.Width, $src.Height)
            $g.Dispose()
            $tmp = "$png.$PID.tmp"
            $dst.Save($tmp, [Drawing.Imaging.ImageFormat]::Png)
            $dst.Dispose()
            try { [IO.File]::Move($tmp, $png) } catch { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }   # otro hilo ya la dejo hecha
        }
        finally { $src.Dispose() }
    }
    $bytes = [IO.File]::ReadAllBytes($png)
    $script:ThumbCache[$key] = $bytes
    return , $bytes
}

# Al abrir el Hub convierte todas las miniaturas en otro hilo, para que la pestana Skins no tenga que esperarlas
function Start-ThumbWarmer($game) {
    try {
        $list = @(Get-ModelInfoCached $game | Where-Object { $_.img } | ForEach-Object { Join-Path $_.dir ($_.name + '.bmp') })
        if ($list.Count -eq 0) { return }
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('Root', $Root)
        $rs.SessionStateProxy.SetVariable('list', $list)
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
                . (Join-Path $Root 'lib.ps1')
                foreach ($b in $list) { try { [void](Get-Thumb $b) } catch {} }
            })
        [void]$ps.BeginInvoke()
    }
    catch {}
}

# ================= boton flotante (opcional) =================
$script:OverlayProc = $null

function Start-Overlay([int]$Port, [string]$Token, [int]$Button = 1, [int]$Card = 1) {
    Stop-Overlay
    $f = Join-Path $Root 'overlay.ps1'
    if (-not (Test-Path $f)) { return }
    $gp = ''; if ($game) { $gp = $game }
    $script:OverlayProc = Start-Process powershell -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$f`"", '-Port', $Port, '-Token', $Token, '-HubPid', $PID, '-Root', "`"$Root`"", '-Game', "`"$gp`"", '-Button', $Button, '-Card', $Card)
}

# Segun los ajustes: boton flotante (overlay, apagado por defecto) y tarjeta de /tp (tpcard, encendida por defecto)
function Update-Overlay([int]$Port, [string]$Token) {
    $s = Read-Settings
    $btn = 0; if ($s -and $s.overlay) { $btn = 1 }
    $card = 1; if ($s -and $null -ne $s.tpcard -and -not $s.tpcard) { $card = 0 }
    if ($btn -or $card) { Start-Overlay $Port $Token $btn $card } else { Stop-Overlay }
}

function Stop-Overlay {
    if ($script:OverlayProc -and -not $script:OverlayProc.HasExited) { Stop-Process -Id $script:OverlayProc.Id -Force -ErrorAction SilentlyContinue }
    $script:OverlayProc = $null
}

function Test-OverlayOn { [bool]($script:OverlayProc -and -not $script:OverlayProc.HasExited) }

# Cambia una sola clave de settings.json sin tocar el resto
function Set-Setting([string]$Name, $Value) {
    $o = Read-Settings
    if (-not $o) { $o = [pscustomobject]@{} }
    $o | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    Write-Atomic $SettingsFile ($o | ConvertTo-Json -Depth 8)
}


# ================= mods (mapas, sonidos, modelos... dentro de un .zip) =================
# Todo va a svencoop_addon (nunca a la carpeta del juego). Cada instalacion guarda la lista exacta de archivos
# en svencoop_addon\.hubmods\<id>.json, asi se puede quitar sin tocar nada mas.
$script:ModTopDirs = 'maps', 'models', 'sound', 'sprites', 'scripts', 'gfx', 'media'
$script:ModAllowedExt = 'bsp', 'res', 'cfg', 'txt', 'wad', 'mdl', 'spr', 'wav', 'mp3', 'ogg', 'tga', 'bmp', 'as', 'png', 'jpg'
$script:ModBlockedExt = 'dll', 'exe', 'bat', 'cmd', 'ps1', 'psm1', 'vbs', 'js', 'msi', 'com', 'scr', 'lnk', 'jar', 'sh', 'so'
$script:ModMax = 629145600   # 600 MB
$script:OpenHosts = 'wootguy.github.io', 'scmapdb.wikidot.com', 'gamebanana.com', 'www.moddb.com', 'svencoop.com', 'www.svencoop.com', 'wiki.svencoop.com', 'steamcommunity.com'

# Lo que hace funcionar al Hub no se puede reemplazar con un mod ni quitar desde el launcher
$script:ProtectedRel = 'scripts/plugins/hubtp.as', 'scripts/plugins/teleport.as', 'scripts/plugins/admin/playermanagement.as'
function Test-ProtectedRel([string]$rel) { $l = "$rel".ToLower(); ($script:ProtectedRel -contains $l) -or ($l -like 'scripts/plugins/hubtp*') }

function Get-Essentials($game) {
    $dp = ''
    $f = Join-Path $game 'svencoop\default_plugins.txt'
    if (Test-Path $f) { $dp = Get-Content $f -Raw }
    return @(
        @{ id = 'tp'; name = 'Plugin /tp'; detail = 'HubTP'; ok = [bool](Test-Tp $game) },
        @{ id = 'sp'; name = 'Plugin Teleport (/s y /p)'; detail = 'Teleport'; ok = [bool]($dp -match '(?m)^\s*"script"\s+"Teleport"') },
        @{ id = 'f8'; name = 'Atajo F8 de comandos'; detail = 'userconfig.cfg'; ok = [bool](Test-Bind $game) }
    )
}

function Get-ModsDb($game) { Join-Path $game 'svencoop_addon\.hubmods' }

# Ruta del zip -> ruta relativa dentro del juego (maps/x.bsp). $null = no es contenido de mod (readme...). Lanza error si es peligrosa.
function ConvertTo-ModRel([string]$full) {
    $n = $full.Replace('\', '/').Trim('/')
    if ($n -match '(^|/)\.\.(/|$)' -or $n -match ':') { throw "ruta no permitida: $full" }
    $seg = @($n -split '/')
    $pref = 'svencoop_addon', 'svencoop', 'svencoop_downloads'
    # quita hasta 3 capas de envoltorio: carpeta del zip (repo-main/), svencoop_addon/, etc.
    for ($k = 0; $k -lt 3 -and $seg.Count -gt 1; $k++) {
        $h = $seg[0].ToLower()
        if ($script:ModTopDirs -contains $h) { break }
        if ($pref -contains $h) { $seg = @($seg[1..($seg.Count - 1)]); continue }
        $n2 = $seg[1].ToLower()
        if ($script:ModTopDirs -contains $n2 -or $pref -contains $n2) { $seg = @($seg[1..($seg.Count - 1)]); continue }
        break
    }
    if ($seg.Count -lt 2 -or ($script:ModTopDirs -notcontains $seg[0].ToLower())) { return $null }
    foreach ($s in $seg) { if ($s -notmatch "^[A-Za-z0-9 _.\-&()\[\]']+$" -or $s.EndsWith('.') -or $s.EndsWith(' ')) { throw "nombre de archivo no permitido: $s" } }
    return ($seg -join '/')
}

# Paso 1: guarda el zip subido (sin instalar) y devuelve un resumen para que la persona confirme
function Save-PendingMod($game, $ctx, [string]$fileName) {
    $pdir = Join-Path $Root 'cache\pending'
    New-Item -ItemType Directory -Force $pdir | Out-Null
    Get-ChildItem $pdir -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue
    if ($ctx.Request.ContentLength64 -gt $script:ModMax) { throw 'El archivo es demasiado grande (max 600 MB).' }
    $id = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $zipPath = Join-Path $pdir "$id.zip"
    $fs = [IO.File]::Create($zipPath)
    try { $ctx.Request.InputStream.CopyTo($fs) } finally { $fs.Close() }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        try { $zip = [IO.Compression.ZipFile]::OpenRead($zipPath) } catch { throw 'No es un .zip valido.' }
        try {
            $files = New-Object System.Collections.Generic.List[object]
            $total = [long]0; $blocked = $null; $conf = New-Object System.Collections.Generic.List[string]
            $hasScripts = $false; $skinOnly = $true; $ignored = 0; $dirs = @{}
            foreach ($e in $zip.Entries) {
                if (-not $e.Name) { continue }
                $ext = [IO.Path]::GetExtension($e.Name).TrimStart('.').ToLower()
                if ($script:ModBlockedExt -contains $ext) { if (-not $blocked) { $blocked = $e.Name }; continue }
                $rel = ConvertTo-ModRel $e.FullName
                if (-not $rel -or ($script:ModAllowedExt -notcontains $ext)) { $ignored++; continue }
                if (Test-ProtectedRel $rel) { throw "$rel es parte del Hub y no se puede reemplazar con un mod." }
                $total += $e.Length
                if ($total -gt $script:ModMax) { throw 'Demasiado grande al descomprimir (max 600 MB).' }
                if ($files.Count -ge 6000) { throw 'Demasiados archivos (max 6000).' }
                $files.Add(@{ entry = $e.FullName; rel = $rel; size = $e.Length })
                $top = $rel.Split('/')[0]; if ($dirs.ContainsKey($top)) { $dirs[$top]++ } else { $dirs[$top] = 1 }
                if ($ext -eq 'as' -and $rel -like 'scripts/*') { $hasScripts = $true }
                if ($rel -notlike 'models/player/*') { $skinOnly = $false }
                $w = $rel.Replace('/', '\')
                if ([IO.File]::Exists((Join-Path $game "svencoop_addon\$w")) -or [IO.File]::Exists((Join-Path $game "svencoop\$w"))) { $conf.Add($rel) }
            }
        }
        finally { $zip.Dispose() }
        if ($blocked) { throw "El zip incluye programas ($blocked). Por seguridad no se instala." }
        if ($files.Count -eq 0) { throw 'No encontre archivos de mods (maps, models, sound...).' }
        $name = [IO.Path]::GetFileNameWithoutExtension($fileName) -replace "[^A-Za-z0-9 _.\-&()]", ''
        if (-not $name.Trim()) { $name = "mod-$id" }
        if ($name.Length -gt 60) { $name = $name.Substring(0, 60) }
        Write-Atomic (Join-Path $pdir "$id.json") (@{ id = $id; name = $name.Trim(); total = $total; files = $files.ToArray() } | ConvertTo-Json -Depth 5)
        return @{
            id = $id; name = $name.Trim(); count = $files.Count; mb = [math]::Round($total / 1MB, 1)
            hasScripts = $hasScripts; kind = $(if ($skinOnly) { 'skin' } else { 'mod' })
            conflictCount = $conf.Count; conflicts = @($conf | Select-Object -First 6); dirs = $dirs; ignored = $ignored
        }
    }
    catch { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue; throw }
}

# Paso 2: instala lo que se confirmo. Si algo falla, borra lo que ya habia copiado.
function Install-PendingMod($game, [string]$id) {
    if ($id -notmatch '^[a-f0-9]{12}$') { throw 'Id no valido.' }
    $zipPath = Join-Path $Root "cache\pending\$id.zip"
    $planPath = Join-Path $Root "cache\pending\$id.json"
    if (-not (Test-Path $zipPath) -or -not (Test-Path $planPath)) { throw 'La subida caduco: vuelve a arrastrar el .zip.' }
    $plan = Get-Content $planPath -Raw | ConvertFrom-Json
    $addon = [IO.Path]::GetFullPath((Join-Path $game 'svencoop_addon')) + '\'
    foreach ($f in $plan.files) {
        $w = "$($f.rel)".Replace('/', '\')
        if ([IO.File]::Exists((Join-Path $game "svencoop_addon\$w")) -or [IO.File]::Exists((Join-Path $game "svencoop\$w"))) { throw "Ya existe $($f.rel): quita primero el otro mod." }
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
    $created = New-Object System.Collections.Generic.List[string]
    try {
        $byName = @{}
        foreach ($e in $zip.Entries) { $byName[$e.FullName] = $e }
        foreach ($f in $plan.files) {
            $full = [IO.Path]::GetFullPath((Join-Path $game ('svencoop_addon\' + "$($f.rel)".Replace('/', '\'))))
            if (-not $full.StartsWith($addon, [StringComparison]::OrdinalIgnoreCase)) { throw 'Ruta no permitida.' }
            New-Item -ItemType Directory -Force ([IO.Path]::GetDirectoryName($full)) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($byName["$($f.entry)"], $full, $false)
            $created.Add($full)
        }
    }
    catch { foreach ($c in $created) { Remove-Item $c -Force -ErrorAction SilentlyContinue }; throw }
    finally { $zip.Dispose() }
    $db = Get-ModsDb $game
    New-Item -ItemType Directory -Force $db | Out-Null
    Write-Atomic (Join-Path $db "$id.json") (@{ id = $id; name = "$($plan.name)"; date = (Get-Date -Format 'yyyy-MM-dd'); mb = [math]::Round($plan.total / 1MB, 1); files = @($plan.files | ForEach-Object { "$($_.rel)" }) } | ConvertTo-Json -Depth 4)
    Remove-Item $zipPath, $planPath -Force -ErrorAction SilentlyContinue
    Reset-ModelCache
    return @{ id = $id; name = "$($plan.name)"; count = $created.Count }
}

function Get-InstalledMods($game) {
    $db = Get-ModsDb $game
    if (-not (Test-Path $db)) { return @() }
    $out = @()
    foreach ($f in (Get-ChildItem $db -Filter '*.json' -ErrorAction SilentlyContinue)) {
        try { $m = Get-Content $f.FullName -Raw | ConvertFrom-Json; $out += @{ id = "$($m.id)"; name = "$($m.name)"; date = "$($m.date)"; mb = $m.mb; count = @($m.files).Count } } catch {}
    }
    return @($out | Sort-Object { $_.name })
}

# Quita un mod: solo los archivos que instalo el Hub, a la Papelera de reciclaje
function Remove-Mod($game, [string]$id) {
    if ($id -notmatch '^[a-f0-9]{12}$') { throw 'Id no valido.' }
    $mf = Join-Path (Get-ModsDb $game) "$id.json"
    if (-not (Test-Path $mf)) { throw 'Ese mod no esta instalado.' }
    $m = Get-Content $mf -Raw | ConvertFrom-Json
    $addonRoot = [IO.Path]::GetFullPath((Join-Path $game 'svencoop_addon'))
    Add-Type -AssemblyName Microsoft.VisualBasic
    $dirs = New-Object System.Collections.Generic.HashSet[string]
    foreach ($rel in @($m.files)) {
        if (Test-ProtectedRel $rel) { continue }
        $full = [IO.Path]::GetFullPath((Join-Path $game ('svencoop_addon\' + "$rel".Replace('/', '\'))))
        if (-not $full.StartsWith($addonRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ([IO.File]::Exists($full)) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($full, 'OnlyErrorDialogs', 'SendToRecycleBin')
            [void]$dirs.Add([IO.Path]::GetDirectoryName($full))
        }
    }
    # carpetas que quedaron vacias (sin tocar la raiz de svencoop_addon)
    foreach ($d in ($dirs | Sort-Object { $_.Length } -Descending)) {
        $cur = $d
        while ($cur.Length -gt $addonRoot.Length -and [IO.Directory]::Exists($cur) -and -not (Get-ChildItem $cur -Force -ErrorAction SilentlyContinue)) {
            Remove-Item $cur -Force -ErrorAction SilentlyContinue
            $cur = [IO.Path]::GetDirectoryName($cur)
        }
    }
    Remove-Item $mf -Force
    Reset-ModelCache
}

# Abre un sitio en el navegador, solo de una lista fija (el Hub no abre direcciones arbitrarias)
function Open-AllowedUrl([string]$Url) {
    $u = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u) -or ($u.Scheme -notin 'https', 'http') -or ($script:OpenHosts -notcontains $u.Host)) { throw 'Direccion no permitida.' }
    Start-Process $u.AbsoluteUri
}

function Remove-PendingMod([string]$id) {
    if ($id -notmatch '^[a-f0-9]{12}$') { return }
    Remove-Item (Join-Path $Root "cache\pending\$id.zip"), (Join-Path $Root "cache\pending\$id.json") -Force -ErrorAction SilentlyContinue
}
