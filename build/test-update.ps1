# test-update.ps1 - prueba el actualizador contra un servidor LOCAL (no toca internet ni tu instalacion real).
# Casos: actualizacion buena, archivo manipulado, firma falsa, script nuevo que no compila y vuelta atras (rollback).
$ErrorActionPreference = 'Stop'
$Hub = Split-Path -Parent $PSScriptRoot
$priv = Join-Path $env:USERPROFILE '.svenhub\private.xml'
$files = 'hub.ps1', 'lib.ps1', 'update.ps1', 'overlay.ps1', 'web\index.html', 'plugins\HubTP.as', 'changelog.json'
$utf8 = New-Object Text.UTF8Encoding($false)
$T = Join-Path $env:TEMP ('hub-uptest-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$script:bad = 0
function Ok($c, $m) { if ($c) { Write-Host "  [ok] $m" -ForegroundColor Green } else { $script:bad++; Write-Host "  [XX] $m" -ForegroundColor Red } }

# ---- instalacion de prueba (v1.4.0) ----
$inst = Join-Path $T 'inst'; New-Item -ItemType Directory $inst | Out-Null
foreach ($f in $files + 'version.txt', 'pubkey.xml') { $d = Join-Path $inst $f; New-Item -ItemType Directory -Force (Split-Path $d) | Out-Null; Copy-Item (Join-Path $Hub $f) $d }
$localVer = (Get-Content (Join-Path $inst 'version.txt') -Raw).Trim()
$newVer = '99.0.0'

# ---- feed de prueba (v99.0.0) firmado con tu llave real ----
function New-Feed([string]$name, [scriptblock]$mutate, [bool]$goodSig = $true) {
    $feed = Join-Path $T $name; New-Item -ItemType Directory -Force "$feed\files" | Out-Null
    foreach ($f in $files) { $d = Join-Path "$feed\files" $f.Replace('\', '/'); New-Item -ItemType Directory -Force (Split-Path $d) | Out-Null; Copy-Item (Join-Path $Hub $f) $d }
    & $mutate "$feed\files"
    $m = [ordered]@{ version = $newVer; released = '2026-01-01'; files = @($files | ForEach-Object { [ordered]@{ path = $_.Replace('\', '/'); sha256 = (Get-FileHash (Join-Path "$feed\files" $_.Replace('\', '/')) -Algorithm SHA256).Hash.ToLower() } }) }
    [IO.File]::WriteAllText("$feed\manifest.json", (($m | ConvertTo-Json -Depth 5) -replace "`r`n", "`n"), $utf8)
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    if ($goodSig) { $rsa.FromXmlString((Get-Content $priv -Raw)) }
    $sig = $rsa.SignData([IO.File]::ReadAllBytes("$feed\manifest.json"), 'SHA256')
    [IO.File]::WriteAllText("$feed\manifest.sig", [Convert]::ToBase64String($sig), $utf8)
    return $feed
}
function Serve($dir) {
    $port = Get-Random -Minimum 51000 -Maximum 59000
    $p = Start-Process python -ArgumentList '-m', 'http.server', $port, '--bind', '127.0.0.1' -WorkingDirectory $dir -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 900
    return @{ proc = $p; url = "http://127.0.0.1:$port" }
}
# Ejecuta el actualizador de la instalacion de prueba en un proceso aparte
$runner = Join-Path $T 'runner.ps1'
New-Item -ItemType Directory -Force $T | Out-Null
[IO.File]::WriteAllText($runner, @'
$ErrorActionPreference = 'Stop'
$Root = $env:HUBT_ROOT
$Utf8 = New-Object Text.UTF8Encoding($false)
$Version = (Get-Content (Join-Path $Root 'version.txt') -Raw).Trim()
function Log($m) {}
. (Join-Path $Root 'update.ps1')
if ($env:HUBT_MODE -eq 'restore') { Restore-Previous; '{}' } else { Invoke-SelfUpdate $true | ConvertTo-Json -Compress }
'@, $utf8)
function Run-Update([string]$url, [string]$root, [string]$mode = 'update') {
    $env:HUBT_ROOT = $root; $env:HUBT_MODE = $mode; $env:SVENHUB_UPDATE_URL = $url
    $out = powershell -NoProfile -ExecutionPolicy Bypass -File $runner
    Remove-Item Env:\SVENHUB_UPDATE_URL, Env:\HUBT_ROOT, Env:\HUBT_MODE -ErrorAction SilentlyContinue
    return ($out | ConvertFrom-Json)
}
function Reset-Inst { foreach ($f in $files + 'version.txt') { Copy-Item (Join-Path $Hub $f) (Join-Path $inst $f) -Force }; Remove-Item "$inst\prev", "$inst\update.pending", "$inst\update.skip" -Recurse -Force -ErrorAction SilentlyContinue }

# arranca el Hub de la instalacion de prueba apuntando a un feed local y devuelve su estado
function Boot-HubFrom($feed) {
    Reset-Inst
    $s = Serve $feed
    $env:SVENHUB_UPDATE_URL = $s.url
    $run = Join-Path $inst 'run.json'; Remove-Item $run -ErrorAction SilentlyContinue
    Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$inst\hub.ps1`"", '-NoBrowser' | Out-Null
    for ($i = 0; $i -lt 100 -and -not (Test-Path $run); $i++) { Start-Sleep -Milliseconds 500 }
    $res = @{ up = (Test-Path $run); state = $null }
    if ($res.up) {
        Start-Sleep -Milliseconds 800
        $r = Get-Content $run -Raw | ConvertFrom-Json
        try { $res.state = Invoke-RestMethod "http://127.0.0.1:$($r.port)/api/state" -Headers @{ 'X-Hub' = $r.token }; Invoke-RestMethod "http://127.0.0.1:$($r.port)/api/quit" -Headers @{ 'X-Hub' = $r.token } | Out-Null } catch {}
        Start-Sleep -Seconds 2
    }
    Remove-Item Env:\SVENHUB_UPDATE_URL -ErrorAction SilentlyContinue
    Stop-Process -Id $s.proc.Id -Force -ErrorAction SilentlyContinue
    return $res
}

try {
    Write-Host "Pruebas del actualizador (instalado: v$localVer, feed: v$newVer)" -ForegroundColor Cyan

    # 1) actualizacion buena
    $feed = New-Feed 'good' { param($d) Add-Content "$d\changelog.json" ' ' }
    $s = Serve $feed
    $r = Run-Update $s.url $inst
    Ok ($r.status -eq 'actualizado') "1. actualizacion valida se instala (estado: $($r.status))"
    Ok ((Get-Content "$inst\version.txt" -Raw).Trim() -eq $newVer) '   version.txt pasa a la nueva'
    Ok (Test-Path "$inst\prev\hub.ps1") '   queda copia de seguridad en prev\'
    Ok (Test-Path "$inst\update.pending") '   queda marca "pendiente de confirmar arranque"'
    Stop-Process -Id $s.proc.Id -Force

    # 2) rollback: la marca pendiente sigue => el siguiente arranque vuelve a la anterior
    Run-Update 'http://127.0.0.1:9' $inst 'restore' | Out-Null
    Ok ((Get-Content "$inst\version.txt" -Raw).Trim() -eq $localVer) '2. rollback devuelve la version anterior'
    Ok ((Get-Content "$inst\update.skip" -Raw).Trim() -eq $newVer) '   la version fallida queda anotada para no reintentarla'
    Ok (-not (Test-Path "$inst\update.pending")) '   se limpia la marca pendiente'
    $s = Serve $feed
    $r = Run-Update $s.url $inst
    Ok ($r.status -eq 'omitida') "   no se reintenta la version fallida (estado: $($r.status))"
    Stop-Process -Id $s.proc.Id -Force

    # 3) archivo manipulado (el hash no coincide con el manifiesto firmado)
    Reset-Inst
    $feed = New-Feed 'tamper' { param($d) }
    Add-Content "$feed\files\hub.ps1" '# manipulado despues de firmar'
    $s = Serve $feed
    $r = Run-Update $s.url $inst
    Ok ($r.status -eq 'error' -and "$($r.error)" -match 'hash') "3. archivo manipulado se rechaza ($($r.error))"
    Ok ((Get-Content "$inst\version.txt" -Raw).Trim() -eq $localVer) '   no se instala nada'
    Stop-Process -Id $s.proc.Id -Force

    # 4) firma falsa (otra llave)
    Reset-Inst
    $feed = New-Feed 'fake' { param($d) } $false
    $s = Serve $feed
    $r = Run-Update $s.url $inst
    Ok ($r.status -eq 'firma-invalida') "4. firma de otra llave se rechaza (estado: $($r.status))"
    Ok ((Get-Content "$inst\version.txt" -Raw).Trim() -eq $localVer) '   no se instala nada'
    Stop-Process -Id $s.proc.Id -Force

    # 5) firmado correctamente pero con un hub.ps1 que no compila
    Reset-Inst
    $feed = New-Feed 'broken' { param($d) Add-Content "$d\hub.ps1" "`nfunction Roto( {" }
    $s = Serve $feed
    $r = Run-Update $s.url $inst
    Ok ($r.status -eq 'error' -and "$($r.error)" -match 'no compila') "5. script nuevo que no compila no se instala ($($r.error))"
    Ok ((Get-Content "$inst\version.txt" -Raw).Trim() -eq $localVer) '   se queda la version que funciona'
    Stop-Process -Id $s.proc.Id -Force

    # 6) sin servidor / sin internet: no rompe nada
    Reset-Inst
    $r = Run-Update 'http://127.0.0.1:9' $inst
    Ok ($r.status -eq 'error') "6. sin conexion devuelve error limpio (estado: $($r.status))"

    # 7) integracion: el Hub completo se actualiza, se relanza y confirma su arranque
    $feed = New-Feed 'good2' { param($d) }
    $b = Boot-HubFrom $feed
    Ok ($b.up -and "$($b.state.version)" -eq $newVer) "7. el Hub se actualiza solo al abrir y arranca (dice v$($b.state.version))"
    Ok (-not (Test-Path "$inst\update.pending")) '   confirma el arranque y borra la marca'
    Ok (-not (Test-Path "$inst\update.skip")) '   no anota nada como fallido'

    # 8) integracion: una version firmada y valida que se cae al arrancar => el Hub vuelve solo a la anterior
    $feed = New-Feed 'crash' { param($d) $f = "$d\hub.ps1"; $t = Get-Content $f -Raw; $t = $t.Replace('param([switch]$NoBrowser, [switch]$NoUpdate)', ('param([switch]$NoBrowser, [switch]$NoUpdate)' + "`nthrow 'boom'")); [IO.File]::WriteAllText($f, $t) }
    $b = Boot-HubFrom $feed
    Ok ($b.up -and "$($b.state.version)" -eq $localVer) "8. version que se cae al arrancar: el Hub vuelve a la anterior (dice v$($b.state.version))"
    Ok ((Test-Path "$inst\update.skip") -and (Get-Content "$inst\update.skip" -Raw).Trim() -eq $newVer) '   la version rota queda anotada y no se reintenta'
}
finally {
    Get-Process python -ErrorAction SilentlyContinue | Where-Object { $_.StartTime -gt (Get-Date).AddMinutes(-5) -and $_.MainWindowTitle -eq '' } | Out-Null
    Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:bad) { Write-Host "`n$($script:bad) prueba(s) fallaron." -ForegroundColor Red; exit 1 }
Write-Host "`nTodas las pruebas del actualizador pasaron." -ForegroundColor Green
