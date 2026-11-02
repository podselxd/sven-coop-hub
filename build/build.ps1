param([switch]$SkipSmoke)
# build.ps1 - revisa TODO antes de compilar. Si algo falla, no se genera el .exe (poka-yoke) y se aprende del fallo (kaizen).
$ErrorActionPreference = 'Stop'
$Hub = Split-Path -Parent $PSScriptRoot
$Share = Join-Path $Hub 'Compartir'
$script:fail = 0

function Check($name, [scriptblock]$test) {
    try {
        $msg = & $test
        if ($msg -is [string] -and $msg.StartsWith('SKIP:')) { Write-Host ("  [--] {0}  ({1})" -f $name, $msg.Substring(5).Trim()) -ForegroundColor Yellow }
        else { Write-Host ("  [ok] {0}" -f $name) -ForegroundColor Green }
    }
    catch { $script:fail++; Write-Host ("  [XX] {0}`n       {1}" -f $name, $_.Exception.Message) -ForegroundColor Red }
}

$version = (Get-Content (Join-Path $Hub 'version.txt') -Raw).Trim()
Write-Host "Sven Coop Hub v$version - comprobaciones" -ForegroundColor Cyan

Check 'PowerShell: hub.ps1 y lib.ps1 compilan' {
    foreach ($f in 'hub.ps1', 'lib.ps1', 'update.ps1', 'overlay.ps1') {
        $errs = $null
        [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $Hub $f), [ref]$null, [ref]$errs)
        if ($errs.Count) { throw "$f linea $($errs[0].Extent.StartLineNumber): $($errs[0].Message)" }
    }
}

Check 'JavaScript de la interfaz compila' {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { return 'SKIP: node no esta instalado' }
    $html = Get-Content (Join-Path $Hub 'web\index.html') -Raw -Encoding UTF8
    $js = ([regex]::Matches($html, '(?s)<script>(.*?)</script>') | ForEach-Object { $_.Groups[1].Value }) -join "`n"
    if (-not $js) { throw 'No encontre el <script>.' }
    $tmp = Join-Path $env:TEMP 'hub_build_check.js'
    [IO.File]::WriteAllText($tmp, $js)
    $out = & node --check $tmp 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($out -join ' ') }
}

Check 'HTML: el marcador __TOKEN__ aparece una sola vez' {
    $html = Get-Content (Join-Path $Hub 'web\index.html') -Raw -Encoding UTF8
    $n = ([regex]::Matches($html, '__TOKEN__')).Count
    if ($n -ne 1) { throw "aparece $n veces" }
}

Check 'Plugin HubTP.as: llaves y parentesis balanceados' {
    $t = Get-Content (Join-Path $Hub 'plugins\HubTP.as') -Raw
    $t = [regex]::Replace($t, '(?s)/\*.*?\*/|//[^\r\n]*|"(\\.|[^"\\])*"', '')
    foreach ($pair in @(@('{', '}'), @('(', ')'))) {
        $a = ($t.ToCharArray() | Where-Object { $_ -eq $pair[0] }).Count
        $b = ($t.ToCharArray() | Where-Object { $_ -eq $pair[1] }).Count
        if ($a -ne $b) { throw "$($pair[0]) x$a vs $($pair[1]) x$b" }
    }
    if ($t -match '\.ToLowercase\(') { throw 'ToLowercase no existe en AngelScript de Sven (ya fallo una vez).' }
}

Check 'Actualizaciones: llave publica y direccion https presentes' {
    if (-not (Test-Path (Join-Path $Hub 'pubkey.xml'))) { throw 'Falta pubkey.xml: ejecuta build\make-keys.ps1' }
    $xml = Get-Content (Join-Path $Hub 'pubkey.xml') -Raw
    if ($xml -match '<D>|<P>|<Q>|<DP>|<DQ>|<InverseQ>') { throw 'pubkey.xml contiene parte PRIVADA de la llave. No se compila.' }
    $url = (Get-Content (Join-Path $Hub 'update.url') -Raw).Trim()
    if ($url -notmatch '^https://') { throw "update.url debe ser https: $url" }
}

Check 'Version: formato x.y.z y coincide con la primera novedad' {
    if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "version invalida: $version" }
    $cl = @(); foreach ($e in (Get-Content (Join-Path $Hub 'changelog.json') -Raw -Encoding UTF8 | ConvertFrom-Json)) { $cl += $e }
    if ($cl.Count -eq 0) { throw 'changelog.json vacio' }
    if ($cl[0].version -ne $version) { throw "version.txt dice $version pero la primera novedad es $($cl[0].version)" }
    if (-not $cl[0].notes -or $cl[0].notes.Count -eq 0) { throw 'la version actual no tiene notas' }
}

if ($SkipSmoke) { Write-Host '  [--] Prueba de humo omitida' -ForegroundColor Yellow }
else {
    Check 'Prueba de humo: el Hub arranca y responde' {
        $tmp = Join-Path $env:TEMP ("hub-smoke-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory $tmp | Out-Null
        Copy-Item (Join-Path $Hub 'hub.ps1'), (Join-Path $Hub 'lib.ps1'), (Join-Path $Hub 'update.ps1'), (Join-Path $Hub 'overlay.ps1'), (Join-Path $Hub 'pubkey.xml'), (Join-Path $Hub 'update.url'), (Join-Path $Hub 'version.txt'), (Join-Path $Hub 'changelog.json') $tmp
        Copy-Item (Join-Path $Hub 'web'), (Join-Path $Hub 'plugins') $tmp -Recurse
        $proc = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$tmp\hub.ps1`"", '-NoBrowser', '-NoUpdate' -PassThru
        try {
            $run = Join-Path $tmp 'run.json'
            for ($i = 0; $i -lt 40 -and -not (Test-Path $run); $i++) { Start-Sleep -Milliseconds 250 }
            if (-not (Test-Path $run)) { throw 'El Hub no arranco en 10 s. ' + (Get-Content (Join-Path $tmp 'hub.log') -ErrorAction SilentlyContinue | Select-Object -Last 3) }
            $r = Get-Content $run -Raw | ConvertFrom-Json
            $h = @{ 'X-Hub' = $r.token }; $u = "http://127.0.0.1:$($r.port)"
            $page = (Invoke-WebRequest "$u/" -UseBasicParsing).Content
            if ($page -match '__TOKEN__') { throw 'La pagina salio sin token.' }
            $st = Invoke-RestMethod "$u/api/state" -Headers $h
            foreach ($k in 'version', 'changelog', 'screen', 'models', 'steamRunning', 'overlay') { if ($null -eq $st.PSObject.Properties[$k]) { throw "/api/state no trae '$k'" } }
            $clN = 0; foreach ($e in $st.changelog) { $clN++ }
            if ($clN -lt 2 -or -not $st.changelog[0].version) { throw "las novedades llegan mal ($clN entradas)" }
            if ($st.version -ne $version) { throw "el Hub dice v$($st.version) y deberia ser v$version" }
            # skins: objetos con nombre, miniatura PNG y proteccion contra nombres maliciosos
            if (@($st.models).Count -gt 0) {
                $m0 = @($st.models)[0]
                if (-not $m0.name) { throw '/api/state: models no trae objetos con name' }
                $withImg = @($st.models | Where-Object { $_.img }) | Select-Object -First 1
                if ($withImg) {
                    $im = Invoke-WebRequest ("$u/api/modelimg?t=$($r.token)&n=" + [uri]::EscapeDataString($withImg.name)) -UseBasicParsing
                    if ($im.Headers['Content-Type'] -ne 'image/png') { throw "la miniatura no es PNG ($($im.Headers['Content-Type']))" }
                }
                $bad = Invoke-RestMethod "$u/api/skindel" -Headers $h -Method Post -Body '{"name":"..\\x"}'
                if ($bad.ok) { throw 'skindel acepto un nombre malicioso' }
            }
            if ($st.gamePath) {
                $mods = Invoke-RestMethod "$u/api/mods" -Headers $h
                if ($null -eq $mods.PSObject.Properties['mods']) { throw '/api/mods no devuelve la lista' }
                $ou = Invoke-RestMethod "$u/api/openurl" -Headers $h -Method Post -Body '{"url":"https://evil.example/"}'
                if ($ou.ok) { throw 'openurl abrio un sitio que no esta en la lista' }
                $mz = Invoke-RestMethod "$u/api/modupload?file=x.zip" -Headers $h -Method Post -Body 'no-es-un-zip' -ContentType 'application/octet-stream'
                if ($mz.ok) { throw 'modupload acepto algo que no es un zip' }
            }
            $hubErr = Invoke-RestMethod "$u/api/skinadd" -Headers $h -Method Post -Body 'no-es-un-zip' -ContentType 'application/octet-stream'
            if ($st.gamePath -and $hubErr.ok) { throw 'skinadd acepto algo que no es un zip' }
            $hl = Invoke-RestMethod "$u/api/health" -Headers $h
            if (@($hl.items).Count -lt 1) { throw '/api/health vacio' }
            $denied = $false; try { Invoke-RestMethod "$u/api/state" | Out-Null } catch { $denied = $true }
            if (-not $denied) { throw 'La API respondio sin token.' }
            Invoke-RestMethod "$u/api/quit" -Headers $h | Out-Null
        }
        finally {
            if (-not $proc.HasExited) { Start-Sleep -Seconds 1; if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } }
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($script:fail -gt 0) { Write-Host "`n$($script:fail) comprobacion(es) fallaron: NO se genero el .exe." -ForegroundColor Red; exit 1 }

# ---- compilar ----
Write-Host "`nCompilando..." -ForegroundColor Cyan
$ico = Join-Path $PSScriptRoot 'hub.ico'
if (-not (Test-Path $ico) -or (Get-Item $ico).LastWriteTime -lt (Get-Item (Join-Path $PSScriptRoot 'make-icon.ps1')).LastWriteTime) { & (Join-Path $PSScriptRoot 'make-icon.ps1') -Out $ico | Out-Null }
New-Item -ItemType Directory -Force $Share | Out-Null
$exe = Join-Path $Share 'SvenCoopHub.exe'
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$res = @('hub.ps1,hub.ps1', 'lib.ps1,lib.ps1', 'update.ps1,update.ps1', 'overlay.ps1,overlay.ps1', 'pubkey.xml,pubkey.xml', 'update.url,update.url', 'version.txt,version.txt', 'changelog.json,changelog.json', 'web\index.html,web/index.html', 'plugins\HubTP.as,plugins/HubTP.as')
$args2 = @('/nologo', '/target:winexe', "/out:$exe", "/win32icon:$ico") + ($res | ForEach-Object { $p = $_ -split ','; "/resource:$(Join-Path $Hub $p[0]),$($p[1])" }) + (Join-Path $PSScriptRoot 'Stub.cs')
& $csc @args2
if ($LASTEXITCODE -ne 0) { Write-Host 'csc fallo.' -ForegroundColor Red; exit 1 }

@"
SVEN COOP HUB v$version
1. Abre Steam y ejecuta SvenCoopHub.exe (Windows avisa: Mas informacion > Ejecutar de todas formas).
2. Unirme: pega la invitacion de tu amigo.
3. Si algo falla: Ajustes > Reparar todo.
"@ | Set-Content (Join-Path $Share 'LEEME.txt') -Encoding UTF8
Compress-Archive -Path $exe, (Join-Path $Share 'LEEME.txt') -DestinationPath (Join-Path $Share 'SvenCoopHub.zip') -Force

$sha = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLower()
Write-Host ("`nListo: v{0}  {1} KB  sha256 {2}" -f $version, [int]((Get-Item $exe).Length / 1KB), $sha.Substring(0, 16)) -ForegroundColor Green
