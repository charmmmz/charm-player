# NAS Relay Onboarding Design

## Goal

Reduce setup for the optional NAS relay while preserving the existing fully local APNs provider model.

## Decisions

- Sonos discovery is automatic by default. `SONOS_SEED_IP` remains as an optional override for networks where SSDP/multicast discovery fails.
- The relay advertises itself on the LAN with Bonjour/mDNS as `_charmrelay._tcp`.
- The iOS app discovers `_charmrelay._tcp`, probes `/api/health`, and uses the first healthy relay when no manual relay URL is configured.
- Manual relay URL remains highest priority and is not overwritten by automatic discovery.
- APNs provider values that are not private can have app-specific defaults:
  - `APNS_BUNDLE_ID=com.charm.SonosWidget`
  - `APNS_TEAM_ID=3MSS7DJGVR`
  - `APNS_KEY_PATH=/app/data/apns.p8`
- `APNS_KEY_ID` can be provided as an image/env default once the production key is known. The `.p8` private key is not committed and is not required for relay startup.
- `APNS_PRODUCTION` remains explicit because Xcode debug builds use sandbox APNs and TestFlight/App Store builds use production APNs.

## User Flow

1. User starts the NAS relay container with host networking.
2. Relay auto-discovers Sonos by SSDP. If that fails, health/logs indicate that `SONOS_SEED_IP` is the fallback.
3. Relay advertises itself via Bonjour.
4. iOS app auto-discovers the relay, probes health, and enables relay-backed Live Activity registration.
5. Settings shows relay connection status, Sonos discovery mode, APNs readiness, and APNs environment.
6. If `.p8` is missing, relay still runs in dry-run mode; full background Live Activity updates require adding `/app/data/apns.p8` and APNs key metadata.

## Non-Goals

- No central APNs broker.
- No FCM/Google dependency.
- No APNs private key in source control.
- No cross-subnet relay discovery beyond manual URL fallback.

