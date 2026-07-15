# solid-gcp Firebase emulators image

Prebuilt Firestore + Firebase Auth emulators for local `SolidGcp::Cable`
development — no local JRE or `firebase-tools` install needed. Generic: apps
mount their own `firebase.json` / `firestore.rules` over the baked-in defaults.

Image tags track the pinned `firebase-tools` version (not gem releases).

## Quickstart

```bash
docker run --rm -p 8080:8080 -p 9099:9099 \
  ghcr.io/cruglobal/solid-gcp-firebase-emulators:15.23.0
```

Firestore is on `localhost:8080`, Auth on `localhost:9099`. Point the gem at them:

```bash
export FIRESTORE_EMULATOR_HOST=127.0.0.1:8080
export FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099
```

The default config has no rules -> emulator allows all reads/writes. Fine to
start; mount your own config for rules parity with prod (below).

## docker-compose (mount your own config + rules)

```yaml
services:
  firebase-emulators:
    image: ghcr.io/cruglobal/solid-gcp-firebase-emulators:15.23.0
    ports: ["8080:8080", "9099:9099"]
    volumes:
      - ./firebase.json:/firebase/firebase.json:ro
      - ./firestore.rules:/firebase/firestore.rules:ro
```

A mounted `firebase.json` **must** keep the emulator hosts at `0.0.0.0` (so
docker port mapping reaches them) and can reference `firestore.rules` for rules
parity with production:

```json
{
  "firestore": { "rules": "firestore.rules" },
  "emulators": {
    "firestore": { "host": "0.0.0.0", "port": 8080 },
    "auth": { "host": "0.0.0.0", "port": 9099 },
    "ui": { "enabled": false }
  }
}
```
