#!/usr/bin/env bash
set -euo pipefail

# === Paramètres à adapter ===
ORG="NICOLASBLOND"
REPO="mqtt_edge"
APP="${APP:-edge-gateway}"                  # nom du binaire
VERSION="${1:-latest}"                      # ex: v1.2.3 ou 'latest'
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
DATA_DIR="${DATA_DIR:-/var/lib/$APP}"
SERVICE="${SERVICE:-/etc/systemd/system/$APP.service}"
HTTP_ADDR="${HTTP_ADDR:-:8080}"             # UI HTTP
CONFIG_PATH="${CONFIG_PATH:-$DATA_DIR/config.json}"

# --- Détection plate-forme ---
OS="linux"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  armv7l|armv7) ARCH="armv7" ;;
  *) echo "Arch non supportée: $ARCH" >&2; exit 1 ;;
esac

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Manquant: $1" >&2; exit 1; }; }
need_cmd curl
need_cmd tar
need_cmd sha256sum

# --- Résolution version ---
if [ "$VERSION" = "latest" ]; then
  VERSION="$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$ORG/$REPO/releases/latest" \
    | sed -E 's#.*/tag/(v[0-9]+\.[0-9]+\.[0-9]+).*#\1#')"
  [ -n "$VERSION" ] || { echo "Impossible de résoudre 'latest'." >&2; exit 1; }
fi

ASSET="${APP}_${VERSION}_${OS}_${ARCH}.tar.gz"
BASE_URL="https://github.com/$ORG/$REPO/releases/download/$VERSION"
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "==> Téléchargement artefacts $VERSION pour $OS/$ARCH"
curl -fsSL -o "$TMP/$ASSET"           "$BASE_URL/$ASSET"
curl -fsSL -o "$TMP/checksums.txt"    "$BASE_URL/checksums.txt"

echo "==> Vérification SHA-256"
( cd "$TMP" && sha256sum -c --ignore-missing checksums.txt )

# (Option) Vérification de signature cosign du checksums.txt (si publiée)
# curl -fsSL -o "$TMP/checksums.txt.sig" "$BASE_URL/checksums.txt.sig" || true
# curl -fsSL -o "$TMP/checksums.txt.pem" "$BASE_URL/checksums.txt.pem" || true
# if [ -s "$TMP/checksums.txt.sig" ] && [ -s "$TMP/checksums.txt.pem" ]; then
#   need_cmd cosign
#   cosign verify-blob --certificate "$TMP/checksums.txt.pem" \
#     --certificate-oidc-issuer https://token.actions.githubusercontent.com \
#     --certificate-identity-regexp "https://github.com/.*/.*/.+" \
#     --signature "$TMP/checksums.txt.sig" "$TMP/checksums.txt"
# fi

echo "==> Extraction"
tar -xf "$TMP/$ASSET" -C "$TMP"
[ -f "$TMP/$APP" ] || { echo "Binaire introuvable dans l’archive." >&2; exit 1; }

echo "==> Installation binaire dans $INSTALL_DIR"
sudo install -m 0755 "$TMP/$APP" "$INSTALL_DIR/$APP"

echo "==> Préparation répertoires de données"
sudo useradd -r -s /usr/sbin/nologin -d "$DATA_DIR" "$APP" 2>/dev/null || true
sudo mkdir -p "$DATA_DIR"
sudo chown -R "$APP:$APP" "$DATA_DIR"

if [ ! -f "$SERVICE" ]; then
  echo "==> Création service systemd"
  sudo tee "$SERVICE" >/dev/null <<EOF
[Unit]
Description=$APP
After=network-online.target
Wants=network-online.target

[Service]
User=$APP
Group=$APP
ExecStart=$INSTALL_DIR/$APP
Environment=HTTP_ADDR=$HTTP_ADDR
Environment=CONFIG_PATH=$CONFIG_PATH
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$DATA_DIR

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now "$APP"
else
  echo "==> Redémarrage du service"
  sudo systemctl restart "$APP"
fi

echo "✅ Installé: $APP $VERSION"
echo "UI: http://<ip>$HTTP_ADDR"
