param(
  [string]$Org = "NICOLASBLOND",
  [string]$Repo = "mqtt_edge",
  [string]$App = "edge-gateway",
  [string]$Version = "latest",   # ex "v1.0.0"
  [string]$InstallDir = "C:\Program Files\edge-gateway",
  [string]$DataDir = "C:\ProgramData\edge-gateway",
  [string]$HttpAddr = ":8080",
  [switch]$CreateService,        # nécessite NSSM (recommandé)
  [string]$NssmPath = ""         # si NSSM n'est pas dans le PATH
)

$ErrorActionPreference = "Stop"

function Get-Arch {
  switch ($env:PROCESSOR_ARCHITECTURE) {
    "AMD64" { "amd64" }
    "ARM64" { "arm64" }
    default { throw "Architecture non supportée: $env:PROCESSOR_ARCHITECTURE" }
  }
}

function Require-Cmd($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Commande manquante: $name"
  }
}

Require-Cmd "Invoke-WebRequest"
Require-Cmd "tar"
Require-Cmd "Get-FileHash"

$arch = Get-Arch
$os = "windows"

# Résolution 'latest'
if ($Version -eq "latest") {
  $resp = Invoke-WebRequest -Uri "https://github.com/$Org/$Repo/releases/latest" -MaximumRedirection 0 -ErrorAction SilentlyContinue
  $redir = $resp.Headers.Location
  if (-not $redir) { throw "Impossible de résoudre 'latest'." }
  if ($redir -match "/tag/(v[0-9]+\.[0-9]+\.[0-9]+)") { $Version = $Matches[1] } else { throw "Tag non trouvé dans $redir" }
}

$asset = "$App" + "_" + "$Version" + "_" + "$os" + "_" + "$arch" + ".tar.gz"
$base = "https://github.com/$Org/$Repo/releases/download/$Version"

$tmp = New-Item -ItemType Directory -Path ([System.IO.Path]::GetTempPath() + [System.Guid]::NewGuid().ToString()) -Force
try {
  Write-Host "==> Téléchargement artefacts $Version ($os/$arch)…"
  Invoke-WebRequest -Uri "$base/$asset" -OutFile "$($tmp.FullName)\$asset"
  Invoke-WebRequest -Uri "$base/checksums.txt" -OutFile "$($tmp.FullName)\checksums.txt"

  Write-Host "==> Vérification SHA-256"
  $expected = (Get-Content "$($tmp.FullName)\checksums.txt" | Where-Object { $_ -match [regex]::Escape($asset) }).Split(' ')[0].Trim()
  if (-not $expected) { throw "Empreinte attendue introuvable." }
  $hash = (Get-FileHash "$($tmp.FullName)\$asset" -Algorithm SHA256).Hash.ToLower()
  if ($hash -ne $expected) { throw "Hash mismatch pour $asset" }

  Write-Host "==> Extraction"
  tar -xf "$($tmp.FullName)\$asset" -C "$($tmp.FullName)"
  if (-not (Test-Path "$($tmp.FullName)\$App.exe")) { throw "Binaire $App.exe introuvable dans l’archive." }

  Write-Host "==> Installation dans $InstallDir"
  New-Item -Force -ItemType Directory -Path $InstallDir | Out-Null
  Copy-Item -Force "$($tmp.FullName)\$App.exe" (Join-Path $InstallDir "$App.exe")

  Write-Host "==> Préparation répertoires de données"
  New-Item -Force -ItemType Directory -Path $DataDir | Out-Null

  # Pare-feu pour l’UI
  $ruleName = "$App-HTTP-$HttpAddr"
  if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
    $port = ($HttpAddr -replace "^[^:]*:", "")
    if ($port -match "^[0-9]+$") {
      New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port | Out-Null
    }
  }

  if ($CreateService) {
    # Service via NSSM (recommandé)
    $nssm = if ($NssmPath -and (Test-Path $NssmPath)) { $NssmPath } else { (Get-Command nssm -ErrorAction SilentlyContinue).Source }
    if (-not $nssm) {
      Write-Warning "NSSM introuvable. Installez-le (choco install nssm) ou relancez sans -CreateService."
    } else {
      & $nssm stop $App 2>$null | Out-Null
      & $nssm remove $App confirm 2>$null | Out-Null
      & $nssm install $App (Join-Path $InstallDir "$App.exe")
      & $nssm set $App AppDirectory $InstallDir
      & $nssm set $App AppEnvironmentExtra ("HTTP_ADDR=$HttpAddr CONFIG_PATH=$DataDir\config.json")
      & $nssm set $App AppStdout (Join-Path $DataDir "stdout.log")
      & $nssm set $App AppStderr (Join-Path $DataDir "stderr.log")
      & $nssm set $App Start SERVICE_AUTO_START
      Start-Service $App
      Write-Host "Service '$App' démarré."
    }
  } else {
    Write-Host ""
    Write-Host "✅ Installé: $App $Version"
    Write-Host "Lancer en console :"
    Write-Host "  set HTTP_ADDR=$HttpAddr"
    Write-Host "  set CONFIG_PATH=$DataDir\config.json"
    Write-Host ("  " + (Join-Path $InstallDir "$App.exe"))
  }
}
finally {
  Remove-Item -Recurse -Force $tmp
}
