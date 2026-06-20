# Setup Walkthrough

This is the order I actually did things in, with the reasoning behind each step. Adjust IPs, domain names, and interface names to match your own network.

## 1. Fresh Ubuntu install

Standard stuff — update everything first.

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install git curl wget build-essential -y
```

## 2. Install OpenTAKServer

```bash
curl -s -L https://i.opentakserver.io/ubuntu_installer | bash -
```

Run this as a regular user, not root. Let it fully finish before touching anything else — it sets up Nginx, the database, and certificates on its own.

## 3. Set up DuckDNS

I run the DuckDNS updater as a Docker container so it keeps my domain pointed at my current public IP automatically.

```bash
sudo apt install docker.io docker-compose-v2 -y
sudo usermod -aG docker $USER
```

Then `docker-compose.yml` in this repo (fill in your own token):

```yaml
services:
  duckdns:
    image: lscr.io/linuxserver/duckdns:latest
    container_name: duckdns
    network_mode: host
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=YOUR_TIMEZONE
      - SUBDOMAINS=yoursubdomain
      - TOKEN=YOUR_DUCKDNS_TOKEN
      - UPDATE_IP=ipv4
      - LOG_FILE=false
    volumes:
      - ./config:/config
    restart: unless-stopped
```

```bash
docker compose up -d
```

**Note on iptables:** Docker requires `iptables-legacy`, not the newer `iptables-nft`. If you hit permission errors with iptables rules elsewhere (like WireGuard's NAT rules), check:

```bash
sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
```

## 4. Port forward on the router (temporary, for setup only)

To get the SSL certificate working initially, port 80 needs to reach the server. I added this in my router's port forwarding / virtual server section:

| External Port | Internal Port | Protocol |
|---------------|----------------|----------|
| 80 | 80 | TCP |

## 5. Get an SSL certificate

```bash
sudo apt install certbot -y
sudo systemctl stop nginx
sudo certbot certonly --standalone --preferred-challenges http -d yoursubdomain.duckdns.org
sudo systemctl start nginx
```

Then point Nginx at the new certificate instead of OpenTAKServer's self-signed one. Edit `/etc/nginx/sites-enabled/ots_https` and `/etc/nginx/sites-enabled/ots_certificate_enrollment`:

```nginx
ssl_certificate /etc/letsencrypt/live/yoursubdomain.duckdns.org/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/yoursubdomain.duckdns.org/privkey.pem;
```

```bash
sudo nginx -t
sudo systemctl restart nginx
```

## 6. Set up WireGuard

```bash
sudo apt install wireguard wireguard-tools qrencode -y
```

Generate server keys:

```bash
sudo mkdir -p /etc/wireguard
wg genkey | sudo tee /etc/wireguard/server_private.key | wg pubkey | sudo tee /etc/wireguard/server_public.key
sudo chmod 600 /etc/wireguard/server_private.key
```

Server config at `/etc/wireguard/wg0.conf`:

```ini
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = YOUR_SERVER_PRIVATE_KEY
```

I deliberately left `PostUp`/`PostDown` out of this file and run the iptables rules as a separate step — running them inline inside `wg-quick` ran into permission issues for me.

```bash
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0
```

Then add the forwarding rules (find your real interface name first with `ip route | grep default`):

```bash
sudo iptables -A FORWARD -i wg0 -j ACCEPT
sudo iptables -A FORWARD -o wg0 -j ACCEPT
sudo iptables -t nat -A POSTROUTING -o YOUR_INTERFACE -j MASQUERADE
```

Enable IP forwarding:

```bash
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

Open the firewall:

```bash
sudo ufw allow 51820/udp
sudo ufw route allow in on wg0
sudo ufw route allow out on wg0
```

## 7. Lock Nginx to VPN-only access

Once WireGuard is confirmed working, I changed Nginx to only listen on the VPN's internal address instead of all interfaces. In `/etc/nginx/sites-enabled/ots_https`:

```nginx
listen 10.0.0.1:443 ssl;
listen 10.0.0.1:8443 ssl;
```

I also kept a line listening on my local network IP so I can reach the server from my own desk without needing the VPN myself:

```nginx
listen 10.0.0.1:443 ssl;
listen 192.168.X.X:443 ssl;   # your server's LAN IP
```

Same pattern in `ots_certificate_enrollment` for port 8446.

```bash
sudo nginx -t
sudo systemctl restart nginx
```

## 8. Remove the public port forwarding rules

Now that the VPN works, go back to the router and delete every port forwarding rule **except**:

| External Port | Internal Port | Protocol |
|---------------|----------------|----------|
| 51820 | 51820 | UDP |
| 22 | 22 | TCP |

## 9. Set up dnsmasq for clean DNS over the VPN

Without this, the domain name resolves to your public IP even while connected to the VPN, and Nginx no longer listens there — so the domain just times out. dnsmasq fixes this for anyone connected to the VPN.

```bash
sudo apt install dnsmasq -y
```

`/etc/dnsmasq.conf`:

```
address=/yoursubdomain.duckdns.org/10.0.0.1
interface=wg0
bind-interfaces
no-hosts
```

**Important:** dnsmasq needs `wg0` to already exist when it starts, or it'll fail with "unknown interface wg0." I added a systemd override to fix the startup order — see `systemd/dnsmasq-override.conf` in this repo, copy it to `/etc/systemd/system/dnsmasq.service.d/override.conf`.

```bash
sudo systemctl daemon-reload
sudo systemctl restart wg-quick@wg0
sudo systemctl restart dnsmasq
```

## 10. Test

Connect a phone to WireGuard on mobile data (WiFi off), then visit `https://yoursubdomain.duckdns.org`. Should load cleanly with a valid certificate, no warnings.

Turn WireGuard off and try again — it should fail to connect. That confirms the lockdown is actually working.
