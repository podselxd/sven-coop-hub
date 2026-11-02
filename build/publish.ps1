param([switch]$SkipBuild, [switch]$DocsOnly, [switch]$Release, [string]$Repo = 'podselxd/sven-coop-hub')
# publish.ps1 - publica la version actual para que los Hub la descarguen solos.
# 1) build.ps1 (todas las comprobaciones)  2) manifest.json con SHA-256 de cada archivo  3) firma con tu llave privada
# 4) git push al repositorio  5) comprobacion de punta a punta: se descarga desde internet y se verifica la firma.
# -DocsOnly: solo README, capturas y scripts de compilacion (no toca files\ ni el manifiesto: los Hub no ven ningun cambio).
# -Release : ademas crea/actualiza la release v<version> de GitHub con Compartir\SvenCoopHub.exe y .zip.
$ErrorActionPreference = 'Stop'
$Hub = Split-Path -Parent $PSScriptRoot
$version = (Get-Content (Join-Path $Hub 'version.txt') -Raw).Trim()
$priv = Join-Path $env:USERPROFILE '.svenhub\private.xml'
$work = Join-Path $env:USERPROFILE '.svenhub\repo'
$base = "https://raw.githubusercontent.com/$Repo/main"
$files = 'hub.ps1', 'lib.ps1', 'update.ps1', 'overlay.ps1', 'web\index.html', 'plugins\HubTP.as', 'changelog.json'
$utf8 = New-Object Text.UTF8Encoding($false)

function Sha([string]$path) { (Get-FileHash $path -Algorithm SHA256).Hash.ToLower() }
function Copy-Tree([string]$src, [string]$dst) {
    New-Item -ItemType Directory -Force $dst | Out-Null
    Get-ChildItem $dst -File -ErrorAction SilentlyContinue | Remove-Item -Force   # lo que ya no existe en el origen tampoco queda en el repositorio
    Copy-Item (Join-Path $src '*') $dst -Force -Include '*.ps1', '*.cs', '*.ico', '*.png'
}

$pubRsa = New-Object Security.Cryptography.RSACryptoServiceProvider
$pubRsa.FromXmlString((Get-Content (Join-Path $Hub 'pubkey.xml') -Raw))
New-Item -ItemType Directory -Force $work | Out-Null

if (-not $DocsOnly) {
    if (-not (Test-Path $priv)) { throw "No encuentro tu llave privada ($priv). Ejecuta build\make-keys.ps1" }
    if (-not $SkipBuild) { & (Join-Path $PSScriptRoot 'build.ps1'); if ($LASTEXITCODE -ne 0) { throw 'build.ps1 fallo: no se publica.' } }
    # poka-yoke: nunca se publica algo que el propio actualizador no sea capaz de instalar y revertir
    & (Join-Path $PSScriptRoot 'test-update.ps1'); if ($LASTEXITCODE -ne 0) { throw 'test-update.ps1 fallo: no se publica.' }

    # --- poka-yoke: no se puede publicar otro contenido con el mismo numero de version ---
    try {
        $remote = [Text.Encoding]::UTF8.GetString((New-Object Net.WebClient).DownloadData("$base/manifest.json")).TrimStart([char]0xFEFF) | ConvertFrom-Json
        if ([version]$remote.version -gt [version]$version) { throw "En internet ya esta la v$($remote.version), mas nueva que la v$version." }
        if ([version]$remote.version -eq [version]$version) {
            foreach ($f in $remote.files) { if ((Sha (Join-Path $Hub ($f.path.Replace('/', '\')))) -ne $f.sha256) { throw "La v$version ya esta publicada con otro contenido. Sube el numero en version.txt y changelog.json." } }
            Write-Host "La v$version ya esta publicada y es identica. Nada que hacer (usa -DocsOnly para README/capturas, -Release para la descarga)." -ForegroundColor Yellow; exit 0
        }
    }
    catch [Net.WebException] { Write-Host 'Aun no hay manifiesto publicado (primera publicacion).' -ForegroundColor Yellow }

    # --- carpeta del repositorio: archivos que se descargan al actualizar ---
    foreach ($f in $files) {
        $dst = Join-Path $work ('files\' + $f)
        New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
        Copy-Item (Join-Path $Hub $f) $dst -Force
    }
    $manifest = [ordered]@{
        version  = $version
        released = (Get-Date -Format 'yyyy-MM-dd')
        files    = @($files | ForEach-Object { [ordered]@{ path = $_.Replace('\', '/'); sha256 = (Sha (Join-Path $Hub $_)) } })
    }
    $mPath = Join-Path $work 'manifest.json'
    [IO.File]::WriteAllText($mPath, (($manifest | ConvertTo-Json -Depth 5) -replace "`r`n", "`n"), $utf8)

    # --- firmar los bytes exactos del manifest.json ---
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    $rsa.FromXmlString((Get-Content $priv -Raw))
    $bytes = [IO.File]::ReadAllBytes($mPath)
    $sig = $rsa.SignData($bytes, 'SHA256')
    [IO.File]::WriteAllText((Join-Path $work 'manifest.sig'), [Convert]::ToBase64String($sig), $utf8)
    if (-not $pubRsa.VerifyData($bytes, 'SHA256', $sig)) { throw 'La firma no verifica con pubkey.xml: la llave publica del exe no corresponde a tu llave privada.' }
}

# --- README, capturas, scripts de compilacion, llave publica ---
Copy-Item (Join-Path $Hub 'README.md') (Join-Path $work 'README.md') -Force
Copy-Tree (Join-Path $Hub 'docs') (Join-Path $work 'docs')
Copy-Tree (Join-Path $Hub 'build') (Join-Path $work 'build')
Copy-Item (Join-Path $Hub 'LICENSE') (Join-Path $work 'LICENSE') -Force
Copy-Item (Join-Path $Hub 'pubkey.xml') (Join-Path $work 'pubkey.xml') -Force
Copy-Item (Join-Path $Hub 'update.url') (Join-Path $work 'update.url') -Force
# la llave publica SI se sube; cualquier llave privada, nunca
[IO.File]::WriteAllText((Join-Path $work '.gitignore'), "private*.xml`n*.key`n*.pfx`n", $utf8)
[IO.File]::WriteAllText((Join-Path $work '.gitattributes'), "* -text`n", $utf8)   # sin conversion CRLF/LF: lo publicado == lo hasheado
# poka-yoke: un XML con parametros privados de RSA (D, P, Q) nunca sale de esta maquina
$leak = Get-ChildItem $work -Recurse -File -Filter *.xml -Force | Where-Object { $_.FullName -notmatch '\\\.git\\' -and (Select-String -LiteralPath $_.FullName -Pattern '<D>|<P>|<Q>' -Quiet) }
if ($leak) { throw "Hay una llave privada dentro del repositorio ($($leak[0].Name)): se cancela." }

# --- git ---
$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) { throw 'Falta GitHub CLI (gh).' }
$login = (& gh api user --jq .login).Trim(); $uid = (& gh api user --jq .id).Trim()
$email = "$uid+$login@users.noreply.github.com"   # el correo real no se publica
Push-Location $work
try {
    $ErrorActionPreference = 'Continue'   # los avisos de git/gh por stderr no deben abortar el script
    if (-not (Test-Path (Join-Path $work '.git'))) { & git init -b main 2>&1 | Out-Null }
    & git config core.autocrlf false
    & git add -A 2>&1 | Out-Null
    $what = if ($DocsOnly) { "Documentacion (README, capturas, scripts) - Hub v$version" } else { "Hub v$version" }
    $msg = "$what`n`nCo-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
    & git -c "user.name=$login" -c "user.email=$email" commit -m $msg 2>&1 | Out-Null
    $has = @(& git remote)
    if (-not ($has -contains 'origin')) {
        & gh repo view $Repo 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { & git remote add origin "https://github.com/$Repo.git"; & git push -u origin main 2>&1 | Out-Null }
        else { & gh repo create $Repo --public --source . --remote origin --push 2>&1 | Out-Null }
    }
    else { & git push origin main 2>&1 | Out-Null }
    if ($LASTEXITCODE -ne 0) { throw 'git push / gh repo create fallo.' }
    # la descripcion va como JSON UTF-8 desde archivo: por argumento, PowerShell 5.1 estropea los acentos
    $df = Join-Path ([IO.Path]::GetTempPath()) 'hub-repo-desc.json'
    [IO.File]::WriteAllText($df, '{"description":"Lanzador para jugar la campaña de Half-Life en Sven Co-op con amigos: invitación, reglas, comandos de chat, skins y mods."}', $utf8)
    & gh api -X PATCH "repos/$Repo" --input $df 2>&1 | Out-Null
    Remove-Item $df -Force -ErrorAction SilentlyContinue
    & gh repo edit $Repo --add-topic sven-coop --add-topic half-life --add-topic launcher --add-topic powershell 2>&1 | Out-Null
    $sha = (& git rev-parse HEAD).Trim()
    $ErrorActionPreference = 'Stop'
}
finally { Pop-Location }

# --- comprobacion de punta a punta: descargar desde internet y verificar la firma ---
if (-not $DocsOnly) {
    Write-Host 'Comprobando la descarga publica (GitHub tarda unos segundos en servirla)...' -ForegroundColor Cyan
    $ok = $false
    for ($i = 0; $i -lt 30 -and -not $ok; $i++) {
        try {
            $wc = New-Object Net.WebClient; $wc.CachePolicy = New-Object Net.Cache.RequestCachePolicy([Net.Cache.RequestCacheLevel]::NoCacheNoStore)
            $cb = "?cb=$([guid]::NewGuid().ToString('N'))"   # una URL distinta cada vez salta la cache de GitHub
            $mb = $wc.DownloadData("$base/manifest.json$cb")
            $sg = [Convert]::FromBase64String(([Text.Encoding]::ASCII.GetString($wc.DownloadData("$base/manifest.sig$cb"))).Trim())
            $m = $utf8.GetString($mb) | ConvertFrom-Json
            if ($m.version -eq $version -and $pubRsa.VerifyData($mb, 'SHA256', $sg)) {
                foreach ($f in $m.files) { if ((Get-FileHash -InputStream (New-Object IO.MemoryStream(, $wc.DownloadData("$base/files/$($f.path)$cb"))) -Algorithm SHA256).Hash.ToLower() -ne $f.sha256) { throw "hash distinto: $($f.path)" } }
                $ok = $true
            }
        }
        catch { if ($_.Exception.Message -like 'hash distinto*') { throw } }
        if (-not $ok) { Start-Sleep -Seconds 5 }
    }
    if (-not $ok) { throw "No pude verificar la v$version desde internet en 150 s." }
    Write-Host "Publicada y verificada: v$version  ->  https://github.com/$Repo" -ForegroundColor Green
}
else { Write-Host "Documentacion subida (commit $sha)  ->  https://github.com/$Repo" -ForegroundColor Green }

# --- release con la descarga de un solo archivo ---
if ($Release) {
    $exe = Join-Path $Hub 'Compartir\SvenCoopHub.exe'; $zip = Join-Path $Hub 'Compartir\SvenCoopHub.zip'
    foreach ($p in $exe, $zip) { if (-not (Test-Path $p)) { throw "Falta $p : ejecuta build\build.ps1." } }
    if ((Get-Content (Join-Path $Hub 'Compartir\LEEME.txt') -Raw) -notmatch [regex]::Escape("v$version")) { throw "Compartir\ no es de la v$version : ejecuta build\build.ps1 antes de crear la release." }
    $cl = (Get-Content (Join-Path $Hub 'changelog.json') -Raw -Encoding UTF8 | ConvertFrom-Json) | Where-Object { $_.version -eq $version } | Select-Object -First 1
    $notes = "## Sven Coop Hub v$version`n`n" + (($cl.notes | ForEach-Object { "- $_" }) -join "`n") + "`n`nDescarga **SvenCoopHub.exe** y ejecútalo con Steam abierto (Windows puede avisar: *Más información → Ejecutar de todas formas*). El Hub se actualiza solo."
    $nf = Join-Path ([IO.Path]::GetTempPath()) "hub-notes-$version.md"; [IO.File]::WriteAllText($nf, $notes, $utf8)
    $ErrorActionPreference = 'Continue'
    & gh release view "v$version" --repo $Repo 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        & gh release upload "v$version" $exe $zip --clobber --repo $Repo 2>&1 | Out-Null
        & gh release edit "v$version" --notes-file $nf --latest --repo $Repo 2>&1 | Out-Null
    }
    else { & gh release create "v$version" $exe $zip --title "Sven Coop Hub v$version" --notes-file $nf --latest --target $sha --repo $Repo 2>&1 | Out-Null }
    if ($LASTEXITCODE -ne 0) { throw 'gh release fallo.' }
    Remove-Item $nf -Force -ErrorAction SilentlyContinue
    Write-Host "Release v$version  ->  https://github.com/$Repo/releases/latest" -ForegroundColor Green
}
