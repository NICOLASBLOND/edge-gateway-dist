param([string]$Org="NICOLASBLOND", [string]$Repo="edge-gateway-dist", [string]$Version="latest")

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Headers = @{ "User-Agent" = "EdgeGatewayInstaller" }

# Résoudre latest via API
if ($Version -eq "latest") {
  $rel = Invoke-RestMethod -Headers $Headers -Uri "https://api.github.com/repos/$Org/$Repo/releases/latest"
  $Version = $rel.tag_name
}

$App  = "edge-gateway"
$Os   = "windows"
$Arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
$Asset = "${App}_${Version}_${Os}_${Arch}.tar.gz"
$Base  = "https://github.com/$Org/$Repo/releases/download/$Version"

$tmp = New-Item -ItemType Directory -Path ([System.IO.Path]::GetTempPath() + [Guid]::NewGuid()) -Force
try {
  Write-Host "Téléchargement $Asset..."
  Invoke-WebRequest -Headers $Headers -Uri "$Base/$Asset"        -OutFile "$($tmp.FullName)\$Asset"        -UseBasicParsing
  Invoke-WebRequest -Headers $Headers -Uri "$Base/checksums.txt" -OutFile "$($tmp.FullName)\checksums.txt" -UseBasicParsing

  Write-Host "Vérification SHA-256..."
  $expected = (Get-Content "$($tmp.FullName)\checksums.txt" | Where-Object { $_ -match [regex]::Escape($Asset) }).Split(' ')[0].Trim()
  $hash = (Get-FileHash "$($tmp.FullName)\$Asset" -Algorithm SHA256).Hash.ToLower()
  if ($hash -ne $expected) { throw "Hash mismatch pour $Asset" }

  Write-Host "Extraction..."
  tar -xf "$($tmp.FullName)\$Asset" -C "$($tmp.FullName)"

  $dest = "C:\Program Files\edge-gateway"
  New-Item -Force -ItemType Directory -Path $dest | Out-Null
  Copy-Item -Force "$($tmp.FullName)\edge-gateway.exe" (Join-Path $dest "edge-gateway.exe")
  Write-Host "✅ Installé. Lancez: `"$dest\edge-gateway.exe`" (UI sur :8080)"
}
finally { Remove-Item -Recurse -Force $tmp }
