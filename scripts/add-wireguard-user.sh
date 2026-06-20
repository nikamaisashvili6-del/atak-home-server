#!/bin/bash
#
# add-wireguard-user.sh
#
# Adds a new WireGuard peer to the server, generates their client config,
# and outputs a QR code they can scan with the WireGuard mobile app.
#
# Usage: sudo ./add-wireguard-user.sh

set -e

WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/wg0.conf"
SERVER_ENDPOINT="yoursubdomain.duckdns.org:51820"   # <-- change to your domain

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo ./add-wireguard-user.sh"
    exit 1
fi

echo "Enter username (letters, numbers, dashes, underscores only):"
read USERNAME

if [[ "$USERNAME" =~ [^a-zA-Z0-9_-] ]] || [ -z "$USERNAME" ]; then
    echo "Invalid username. No spaces or special characters."
    exit 1
fi

if [ -f "${WG_DIR}/${USERNAME}_private.key" ]; then
    echo "User '$USERNAME' already exists."
    exit 1
fi

# Find the next free IP in the 10.0.0.0/24 range (starting at .2)
LASTOCTET=2
while grep -q "10.0.0.${LASTOCTET}/32" "$WG_CONF" 2>/dev/null; do
    LASTOCTET=$((LASTOCTET + 1))
done

if [ "$LASTOCTET" -gt 254 ]; then
    echo "No free IP addresses left in the 10.0.0.0/24 range."
    exit 1
fi

echo "Assigning IP: 10.0.0.${LASTOCTET}"

# Generate key pair
wg genkey | tee "${WG_DIR}/${USERNAME}_private.key" | wg pubkey | tee "${WG_DIR}/${USERNAME}_public.key" > /dev/null
chmod 600 "${WG_DIR}/${USERNAME}_private.key"

CLIENT_PRIVATE=$(cat "${WG_DIR}/${USERNAME}_private.key")
CLIENT_PUBLIC=$(cat "${WG_DIR}/${USERNAME}_public.key")
SERVER_PUBLIC=$(cat "${WG_DIR}/server_public.key")

# Add peer to server config
{
    echo ""
    echo "[Peer]"
    echo "# ${USERNAME}"
    echo "PublicKey = ${CLIENT_PUBLIC}"
    echo "AllowedIPs = 10.0.0.${LASTOCTET}/32"
} >> "$WG_CONF"

# Build client config
cat > "${WG_DIR}/${USERNAME}.conf" << EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE}
Address = 10.0.0.${LASTOCTET}/32
DNS = 10.0.0.1

[Peer]
PublicKey = ${SERVER_PUBLIC}
Endpoint = ${SERVER_ENDPOINT}
AllowedIPs = 10.0.0.0/24, 192.168.0.0/24
PersistentKeepalive = 25
EOF

# Reload WireGuard without dropping existing connections
wg syncconf wg0 <(wg-quick strip wg0)

# Save QR code as both a file and terminal output
qrencode -t png -o "${WG_DIR}/${USERNAME}_qr.png" < "${WG_DIR}/${USERNAME}.conf"

echo ""
echo "QR code for ${USERNAME}:"
qrencode -t ansiutf8 < "${WG_DIR}/${USERNAME}.conf"

echo ""
echo "Done. Files saved:"
echo "  Config: ${WG_DIR}/${USERNAME}.conf"
echo "  QR PNG: ${WG_DIR}/${USERNAME}_qr.png"
echo ""
echo "Send the QR code to ${USERNAME} so they can scan it in the WireGuard app."
echo "Don't forget to also create their OpenTAKServer login separately."
