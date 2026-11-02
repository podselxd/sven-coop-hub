# make-keys.ps1 - crea (una sola vez) el par de llaves con el que se firman las actualizaciones.
#  - privada: %USERPROFILE%\.svenhub\private.xml  (SOLO en tu PC; nunca va al repo, al zip ni al exe)
#  - publica: pubkey.xml en la carpeta del Hub     (va dentro del exe; con ella cada Hub verifica las firmas)
$ErrorActionPreference = 'Stop'
$Hub = Split-Path -Parent $PSScriptRoot
$dir = Join-Path $env:USERPROFILE '.svenhub'
$priv = Join-Path $dir 'private.xml'
$pub = Join-Path $Hub 'pubkey.xml'
New-Item -ItemType Directory -Force $dir | Out-Null

if (Test-Path $priv) {
    if (-not (Test-Path $pub)) {
        $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
        $rsa.FromXmlString((Get-Content $priv -Raw))
        [IO.File]::WriteAllText($pub, $rsa.ToXmlString($false))
        Write-Host 'pubkey.xml recreada desde la llave privada existente.'
    }
    else { Write-Host 'Las llaves ya existen; no se toca nada.' }
}
else {
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider(3072)
    [IO.File]::WriteAllText($priv, $rsa.ToXmlString($true))
    [IO.File]::WriteAllText($pub, $rsa.ToXmlString($false))
    # solo tu usuario puede leer la privada
    & icacls $priv /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
    Write-Host "Llaves creadas. Privada: $priv"
}
$fp = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes((Get-Content $pub -Raw)))).Replace('-', '').Substring(0, 16).ToLower()
Write-Host "Huella de la llave publica: $fp"
