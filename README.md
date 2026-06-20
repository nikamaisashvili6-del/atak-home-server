# ATAK Home Server

A self-hosted [OpenTAKServer](https://github.com/brian7704/OpenTAKServer) setup running on Ubuntu 26.04, secured behind a WireGuard VPN, with HTTPS via Let's Encrypt and dynamic DNS through DuckDNS.

This is a personal learning project — I wanted to understand networking, VPNs, and self-hosting better, while building something I'd actually use. It's budget-friendly and built entirely with free, open-source tools.

## What this does

- Runs OpenTAKServer (an open-source TAK server) on a home machine
- Locks the web UI and ATAK device ports behind a WireGuard VPN, so nothing is reachable by the public internet except the VPN tunnel itself
- Uses DuckDNS so the server stays reachable by a fixed domain name even though my home IP changes
- Gets a real trusted SSL certificate from Let's Encrypt instead of a self-signed one
- Includes a script to add new VPN users in one command, complete with QR code generation for mobile devices

## Why I built it this way

I didn't want to just open a bunch of ports to the internet and hope for the best. The TAK protocol carries location and mission data, so I wanted only people I've actually invited to be able to reach the server at all — not just people who have a password. WireGuard handles that: you need a cryptographic key that I generate and hand to you, there's no public login page to brute-force in the first place.

## Architecture

```
                    INTERNET
                        │
              ┌─────────────────┐
              │  Public IP       │
              │  (via DuckDNS)   │
              └────────┬─────────┘
                        │
              ┌─────────────────┐
              │  Home Router     │
              │  (only 2 ports   │
              │   forwarded)     │
              └────────┬─────────┘
                        │
              ┌─────────────────────────┐
              │  Ubuntu Server            │
              │                           │
              │  • OpenTAKServer          │
              │  • Nginx (reverse proxy)  │
              │  • WireGuard (VPN)        │
              │  • dnsmasq (VPN DNS)      │
              │  • DuckDNS updater        │
              └───────────────────────────┘
```

Only two ports are open to the public internet:
- `51820/udp` — WireGuard VPN
- `22/tcp` — SSH

Everything else (the web UI, the ATAK device connection ports) only listens on the WireGuard interface. You have to be connected to the VPN to reach any of it.

## Prerequisites

- Ubuntu 26.04 (or similar recent Ubuntu)
- A router you can configure port forwarding on
- A free [DuckDNS](https://www.duckdns.org) account and domain
- Docker (for running the DuckDNS updater)

## Setup

I'm not including a one-click install script here on purpose — networking setup like this depends a lot on your specific router and network, so I'd rather walk through it step by step. See [`docs/SETUP.md`](docs/SETUP.md) for the full walkthrough I followed.

Quick overview of the order I did things in:

1. Install OpenTAKServer using its official installer
2. Set up DuckDNS with a Docker container so my domain always points at my current public IP
3. Get an SSL certificate with Certbot
4. Set up WireGuard and lock Nginx down to only listen on the VPN interface
5. Set up dnsmasq so the domain name resolves correctly once connected to the VPN

## Adding a new user

```bash
sudo ./scripts/add-wireguard-user.sh
```

This will:
- Prompt for a username
- Auto-assign the next available VPN IP
- Generate a fresh key pair for that user
- Add them to the server's WireGuard config
- Generate a QR code they can scan in the WireGuard mobile app

I send people the QR code plus their OpenTAKServer login separately — the VPN gets them onto the network, the OpenTAKServer account is what actually lets them log into the web UI or ATAK app.

## What's NOT in this repo

This is important. None of the following are committed, and you shouldn't commit them either if you fork this:

- `/etc/wireguard/*.conf` — contains private keys
- `/etc/letsencrypt/` — contains your SSL private key
- DuckDNS token
- `ots.db` — the OpenTAKServer database, contains user accounts
- Any `.env` files with real values

See [`.gitignore`](.gitignore) for the full list. The `docker-compose.yml` in this repo uses placeholder values — you need to fill in your own DuckDNS token before running it.

## Known issues I ran into (documented so future-me remembers)

- **iptables conflict with Docker**: Docker only works with `iptables-legacy`, not `iptables-nft`. If WireGuard's `PostUp`/`PostDown` rules fail with "Permission denied," check `sudo update-alternatives --display iptables`.
- **wg0 sometimes starts without an IP assigned**: Occasionally `wg-quick` brings the interface up but doesn't assign the address. If `ping 10.0.0.1` fails from the server itself, check `ip addr show wg0` and manually add it if missing.
- **dnsmasq can fail on boot**: If `wg0` isn't up yet when `dnsmasq` starts, it'll fail with "unknown interface wg0." I added a systemd override so dnsmasq waits for WireGuard — see `systemd/dnsmasq-override.conf`.
- **NAT loopback**: My router doesn't support accessing my own public domain from inside my own network. I work around this with a local `/etc/hosts` entry pointing the domain straight to the server's local IP.

## License

MIT — do whatever you want with this, just don't blame me if you misconfigure your firewall and lock yourself out. (Ask me how I know to back up your WireGuard config before testing changes.)
