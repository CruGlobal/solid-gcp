# syntax=docker/dockerfile:1
# check=error=true

# Prebuilt Firestore + Firebase Auth emulators, so consumers (e.g. Flightdeck)
# get the Cable dev backend without a local JRE + firebase-tools install.
# Generic image: apps mount their own firebase.json / firestore.rules over the
# baked-in defaults (see README.md). Tags track FIREBASE_TOOLS_VERSION.

# trixie (not bookworm) because firebase-tools >=15 requires a Java 21+ runtime,
# and only trixie ships openjdk-21 in its apt repo (bookworm tops out at 17).
FROM node:22-trixie-slim

# Keep in sync with the emulator-image.yml workflow, which greps this ARG to
# derive the pushed tag.
ARG FIREBASE_TOOLS_VERSION=15.23.0

# openjdk JRE is the Firestore emulator's only system dep (it's a Java jar);
# firebase-tools >=15 needs Java 21+.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y openjdk-21-jre-headless && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

RUN npm install -g firebase-tools@${FIREBASE_TOOLS_VERSION}

# Pre-download the Firestore emulator jar at build time so first container start
# is instant (no runtime download). The Auth emulator is pure Node (built into
# firebase-tools) — no jar, nothing to predownload.
# We build and run as root (default): dev-only image, and it keeps the jar cache
# (~/.cache/firebase) readable by the runtime user without extra chown dance.
RUN firebase setup:emulators:firestore

# Baked-in default config. Apps mount their own over this for rules parity.
# host 0.0.0.0 is required so docker port mapping can reach the emulators from
# the host; 127.0.0.1 (firebase's default) would only bind inside the container.
# No firestore.rules reference here -> emulator allows all reads/writes, fine
# for a default; mount a config that references rules for prod-like enforcement.
RUN mkdir -p /firebase && \
    printf '%s\n' '{' \
    '  "emulators": {' \
    '    "firestore": { "host": "0.0.0.0", "port": 8080 },' \
    '    "auth": { "host": "0.0.0.0", "port": 9099 },' \
    '    "ui": { "enabled": false }' \
    '  }' \
    '}' > /firebase/firebase.json

WORKDIR /firebase
EXPOSE 8080 9099
CMD ["firebase", "emulators:start", "--only", "firestore,auth", "--project", "demo-solid-gcp"]
