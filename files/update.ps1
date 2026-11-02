# update.ps1 - auto-actualizacion firmada (se carga desde hub.ps1 junto a lib.ps1)
# Flujo: manifest.json + manifest.sig (RSA/SHA-256, firmado con la llave privada del autor) -> se verifica con pubkey.xml
# -> se descargan los archivos -> se comprueba el SHA-256 de cada uno -> se comprueba que hub.ps1/lib.ps1/update.ps1 compilan
# -> copia de seguridad en prev\ -> se instala. Si la version nueva no llega a arrancar, el siguiente inicio vuelve a la anterior.
$script:UpdateFiles = 'hub.ps1', 'lib.ps1', 'update.ps1', 'overlay.ps1', 'web\index.html', 'plugins\HubTP.as', 'changelog.json'

function Get-Bytes([string]$Url, [int]$TimeoutMs = 4000) {
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Timeout = $TimeoutMs; $req.ReadWriteTimeout = $TimeoutMs
    $req.UserAgent = "SvenCoopHub/$Version"
    $req.CachePolicy = New-Object Net.Cache.RequestCachePolicy([Net.Cache.RequestCacheLevel]::NoCacheNoStore)
    $resp = $req.GetResponse()
    try { $ms = New-Object IO.MemoryStream; $resp.GetResponseStream().CopyTo($ms); return , $ms.ToArray() }
    finally { $resp.Close() }
}

function Get-Sha256([byte[]]$Bytes) { [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($Bytes)).Replace('-', '').ToLower() }

function Get-UpdateBase {
    $u = ''
    $f = Join-Path $Root 'update.url'
    if (Test-Path $f) { $u = (Get-Content $f -Raw).Trim() }
    # solo para pruebas locales: permite apuntar a un servidor en 127.0.0.1
    if ($env:SVENHUB_UPDATE_URL -match '^http://127\.0\.0\.1(:\d+)?(/|$)') { $u = $env:SVENHUB_UPDATE_URL.Trim() }
    elseif ($u -notmatch '^https://') { return '' }
    return $u.TrimEnd('/')
}

function Test-PsSyntax([string]$Path) {
    $errs = $null
    [void][Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    return ($errs.Count -eq 0)
}

# $Apply = $false solo comprueba; $true descarga e instala
function Invoke-SelfUpdate([bool]$Apply = $true) {
    $base = Get-UpdateBase
    $pk = Join-Path $Root 'pubkey.xml'
    if (-not $base -or -not (Test-Path $pk)) { return @{ status = 'disabled' } }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $mb = Get-Bytes "$base/manifest.json"
        $sig = [Convert]::FromBase64String(([Text.Encoding]::ASCII.GetString((Get-Bytes "$base/manifest.sig"))).Trim())
        $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
        $rsa.FromXmlString((Get-Content $pk -Raw))
        if (-not $rsa.VerifyData($mb, 'SHA256', $sig)) { Log 'update: FIRMA INVALIDA, se ignora'; return @{ status = 'firma-invalida' } }
        $m = $Utf8.GetString($mb).TrimStart([char]0xFEFF) | ConvertFrom-Json
        if ([version]$m.version -le [version]$Version) { return @{ status = 'al-dia'; latest = "$($m.version)" } }
        $skip = Join-Path $Root 'update.skip'
        if ((Test-Path $skip) -and ((Get-Content $skip -Raw).Trim() -eq "$($m.version)")) { return @{ status = 'omitida'; latest = "$($m.version)" } }
        if (-not $Apply) { return @{ status = 'disponible'; latest = "$($m.version)"; released = "$($m.released)" } }

        $stage = Join-Path $Root 'update-staging'
        if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
        New-Item -ItemType Directory $stage | Out-Null
        foreach ($f in $m.files) {
            $rel = ("$($f.path)").Replace('/', '\')
            if ($rel -notmatch '^[A-Za-z0-9_.\\-]+$' -or $rel -match '\.\.' -or ($script:UpdateFiles -notcontains $rel)) { throw "ruta no permitida: $($f.path)" }
            $b = Get-Bytes "$base/files/$($f.path)" 15000
            if ((Get-Sha256 $b) -ne "$($f.sha256)") { throw "el hash de $($f.path) no coincide" }
            $dest = Join-Path $stage $rel
            New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
            [IO.File]::WriteAllBytes($dest, $b)
        }
        foreach ($ps in 'hub.ps1', 'lib.ps1', 'update.ps1') {
            $p = Join-Path $stage $ps
            if ((Test-Path $p) -and -not (Test-PsSyntax $p)) { throw "$ps nuevo no compila; no se instala" }
        }
        # copia de seguridad de lo que se va a reemplazar
        $prev = Join-Path $Root 'prev'
        if (Test-Path $prev) { Remove-Item $prev -Recurse -Force }
        New-Item -ItemType Directory $prev | Out-Null
        foreach ($f in $m.files) {
            $rel = ("$($f.path)").Replace('/', '\'); $cur = Join-Path $Root $rel
            if (Test-Path $cur) { $pd = Join-Path $prev $rel; New-Item -ItemType Directory -Force (Split-Path $pd) | Out-Null; Copy-Item $cur $pd -Force }
        }
        Copy-Item (Join-Path $Root 'version.txt') (Join-Path $prev 'version.txt') -Force -ErrorAction SilentlyContinue
        foreach ($f in $m.files) {
            $rel = ("$($f.path)").Replace('/', '\'); $dst = Join-Path $Root $rel
            New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
            [IO.File]::Copy((Join-Path $stage $rel), $dst, $true)
        }
        [IO.File]::WriteAllText((Join-Path $Root 'version.txt'), "$($m.version)`r`n", $Utf8)
        [IO.File]::WriteAllText((Join-Path $Root 'update.pending'), "$($m.version),0", $Utf8)
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
        Log "update: $Version -> $($m.version)"
        return @{ status = 'actualizado'; latest = "$($m.version)" }
    }
    catch { Log "update: $($_.Exception.Message)"; return @{ status = 'error'; error = $_.Exception.Message } }
}

# La version nueva no llego a arrancar: se devuelve la anterior y se anota la nueva para no reintentarla
function Restore-Previous {
    $prev = Join-Path $Root 'prev'
    $bad = ''
    $pf = Join-Path $Root 'update.pending'
    if (Test-Path $pf) { $bad = ((Get-Content $pf -Raw).Trim() -split ',')[0] }
    if (Test-Path $prev) {
        foreach ($f in (Get-ChildItem $prev -Recurse -File)) {
            $rel = $f.FullName.Substring($prev.Length + 1)
            $dst = Join-Path $Root $rel
            New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
            [IO.File]::Copy($f.FullName, $dst, $true)
        }
    }
    if ($bad) { [IO.File]::WriteAllText((Join-Path $Root 'update.skip'), $bad, $Utf8) }
    Remove-Item $pf -Force -ErrorAction SilentlyContinue
}
