# Security Design & Testing

This document explains the security thinking behind the setup: what the design is
protecting against, how the attack surface was deliberately kept small, and how each
assumption was actually *tested* rather than just believed.

It's written as a record of a personal learning project. The interesting part isn't the
tool commands — it's the methodology: reduce what's exposed to almost nothing, then prove
it with before/after testing instead of trusting that a setting "probably works."

---

## Threat model

The service carries data I'd rather not expose to the open internet, so the goal was simple:
**nobody I haven't personally invited should be able to reach the application at all — not
even a login page to attack.**

That reframes the whole problem. Most self-hosted setups expose a web login to the internet
and rely on passwords holding. That leaves a public attack surface: brute force, credential
stuffing, and whatever CVE turns up in the exposed software next month. The design here removes
the surface instead of defending it:

- There is no public login page to attack, because the application isn't reachable from the
  internet at all.
- The only thing exposed is a VPN port that stays completely silent to anyone without a valid
  cryptographic key. Reaching the services *at all* requires a key I generated and handed over
  out-of-band.

Assumed adversaries, in rough order of concern:

1. **Opportunistic internet-wide scanners** — the constant background noise hitting every public
   IP. Defense: present almost no surface, and what little is there doesn't respond to
   unauthenticated packets.
2. **A single-source flood / DoS attempt** — someone trying to knock the service offline from one
   origin. Defense: a protocol that drops invalid packets cheaply, plus router- and host-level
   rate limiting, all tested (see below).
3. **A compromised insider device** — someone already on the VPN whose credential or device is
   taken over. Defense: understand the blast radius; keep internal services minimal and locked
   down so a foothold doesn't hand over everything.

Explicitly **out of scope** (and documented honestly rather than pretended away):
botnet-scale volumetric DDoS. See *Limitations* at the end.

---

## Architecture: attack-surface reduction

The design is layered so that a failure at one layer still leaves the next one standing.

```
        INTERNET  (hostile by default)
            │
            │   exactly ONE port reachable: 51820/udp (VPN)
            │   — silent to any packet without a valid key
            ▼
      ┌───────────────┐
      │  Home router   │  all other inbound forwarding removed
      └───────┬───────┘
            │
            ▼
      ┌─────────────────────────────┐
      │  Server                       │
      │                               │
      │  WireGuard (VPN) ── wg0       │  ← the only way in
      │                               │
      │  All application services     │
      │  bind ONLY to the VPN         │
      │  interface, never to the      │
      │  public or LAN interface:     │
      │    • TAK server               │
      │    • reverse proxy (TLS)      │
      │    • internal DNS             │
      │                               │
      │  Admin access (SSH) is also   │
      │  VPN-only — not exposed to    │
      │  the internet.                │
      └─────────────────────────────┘
```

The key move is that every application service **listens on the VPN interface only**. Even if
the router forwarding were misconfigured tomorrow, the services still wouldn't answer on the
public interface, because they aren't bound to it. The VPN isn't a convenience layer bolted on
top — it's the *only* path to anything.

**Net externally-reachable surface: one UDP port that doesn't reply to strangers.** That is the
entire thing an internet attacker gets to work with.

---

## Testing methodology

A setting you enabled but never tested is a hope, not a control. The whole project ran on one
discipline:

> **Measure the baseline → change exactly one thing → measure again → compare the delta.**

Skipping the "before" measurement means you're assuming the change did something. Measuring both
sides is what turns "I ticked a box" into "I can show this box does X." Two rules kept it honest:

- **One variable at a time.** Change one control between runs, or you can't attribute the result.
- **Verify on the defender's side, not the attacker's.** An attack tool reporting "target down"
  means the *tool* believes it succeeded — which is not the same as the service actually failing.
  Ground truth is the server's own logs, socket state, and service status, plus the real question:
  *could a legitimate user still get through the whole time?*

Testing was split into two vantage points:

- **External audit** — run from a genuinely separate network (a machine on a mobile connection,
  fully outside the LAN) so the results reflect what the internet actually sees, with no
  local-network shortcuts hiding exposure.
- **Internal audit** — run from a machine *on* the VPN, deliberately simulating a compromised
  insider, to map exactly what a foothold would reach.

---

## What was tested, and the result

### External exposure (from outside the network)

- **Full TCP port sweep of the public IP** — confirmed only the expected surface is reachable;
  everything else returns *filtered* (silently dropped by the firewall, not even reporting closed).
- **UDP check on the VPN port** — behaves as designed: it doesn't announce itself, and no other
  UDP service is exposed.
- **Router admin interface** — the router's own management pages (the classic 80/443 admin
  exposure) were confirmed **closed from the internet** after hardening. This was a genuine
  before/after: they responded before the change, and stopped responding after.
- **SSH** — confirmed **filtered from outside**. Administrative access is reachable only once
  you're on the VPN. Nothing to knock on from the public internet.

### Flood / DoS resilience (single source)

Tested from an external connection, kept to short bursts, watching server-side monitors and — the
measurement that actually matters — whether a real client stayed usable throughout:

- **SYN / UDP / ICMP floods from a single source** — no measurable service impact. The VPN
  protocol drops invalid unauthenticated packets cheaply and stays silent, and legitimate peers
  kept their connections alive through the flood. Router- and host-level rate limiting added a
  second layer that visibly banned an over-eager source mid-test.
- **Application-layer attacks (slow-HTTP and request-flood) against the reverse proxy**, run from
  *inside* the VPN to simulate a compromised insider — the proxy defended itself and stayed up;
  all services survived. Notably, the attack tool's own "service unavailable" readout turned out
  to be the *tool* failing to hold connections, not the server dying — confirmed by checking the
  server side directly. A clean example of why attacker-tool output isn't ground truth.

### Internal services (blast-radius audit)

- **Internal DNS resolver** — confirmed **not an open resolver**: it answers only on the VPN
  interface and returns nothing to external queries. (An open resolver is both a security hole and
  a way to get your IP abused in reflection attacks.)
- **Message broker** — confirmed bound to localhost and **not reachable over the VPN** at all, so
  default-credential exposure is a non-issue; changing those credentials remains defense-in-depth,
  not a live hole.
- **TLS quality** — certificates and cipher suites checked per service for weak ciphers and
  outdated protocol versions, and for approaching expiry (a mismatched/expired cert had caused an
  outage once — this check exists specifically so it can't happen silently again).

---

## Methodology lessons (the part worth keeping)

These generalize well beyond this one box, and they're the real takeaways:

- **Attack-tool output ≠ ground truth.** Always confirm impact on the defender's side. A tool
  saying "down" is a claim to verify, not a result to trust.
- **A `filtered` port labelled with a service name is a guess, not a detection.** Port scanners
  attach service names from a static lookup table based on the port number. That's not evidence a
  service is there — check what's *actually* listening on the host itself.
- **"Server unreachable" is usually a network problem, not a server problem.** A public IP that
  still responds only proves the router is alive, not that the service is. More than one "it's all
  down!" panic turned out to be local Wi-Fi.
- **Verify the fix, not just the setting.** After changing a control, re-run the *specific* test
  that exercises it and confirm the state actually changed. The re-test is the whole point.

---

## Limitations (stated honestly)

This setup validates **single-source** flood resilience and, more importantly, a genuinely tiny
attack surface. It does **not** test — and a home connection cannot defend against — true
**volumetric DDoS** at botnet scale. A single origin (even a rented server) can't generate that
kind of traffic, and no host-level configuration matters once the internet uplink itself is
saturated upstream.

The only real defense against serious volumetric attacks is upstream — a service with more
bandwidth than the attacker, absorbing the flood before it reaches the line, or hosting somewhere
built for it. That's out of scope for a personal project and deliberately left as a documented gap
rather than a solved problem. If a system like this ever became a target worth a paid attack, that
fact would itself be the signal to move it off a home connection.

Being explicit about what *wasn't* covered is part of the methodology, not an afterthought. A
security write-up that only lists wins isn't a security write-up.

---

## Tooling

Standard, freely available tooling throughout: `nmap` for exposure mapping and TLS/cipher/DNS
scripts, `hping3` and `slowhttptest`/`ab` for flood and application-layer resilience testing,
`openssl` for certificate inspection, and the host firewall for rate limiting. All testing was
conducted exclusively against infrastructure I own.