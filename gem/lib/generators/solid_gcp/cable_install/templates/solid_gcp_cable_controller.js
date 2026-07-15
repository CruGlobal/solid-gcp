import { Controller } from "@hotwired/stimulus"
import { initializeApp, getApps, getApp } from "firebase/app"
import { getAuth, signInWithCustomToken } from "firebase/auth"
import { getFirestore, doc, onSnapshot } from "firebase/firestore"

// Page-level registry: many stream elements share one token fetch, one sign-in,
// and one Firestore listener per doc. State lives on the module, not per element.
const registry = {
  streams: new Map(), // signedName -> { doc, count }
  fetchScheduled: false,
  app: null,
  db: null,
  unsubscribes: new Map(), // doc -> unsubscribe fn
  live: new Set(),         // docs whose initial snapshot has arrived (listening)
  refreshTimer: null,
  config: null,
  // Retry/backoff state for the setup + attach chain. Firestore auto-refreshes
  // ID tokens hourly on its own (custom claims persist), so steady-state expiry
  // does NOT land here; this covers token-fetch/sign-in failures and listener
  // auth errors (claims/rules changed) only.
  connecting: false, // an attempt is in flight (guards re-entry)
  retryTimer: null,  // pending backoff timer id (null => not backing off)
  attempt: 0,        // consecutive failed attempts
  failed: false,     // gave up after exhausting attempts
  signedIn: false    // have a live Firebase session covering current streams
}

// Jittered exponential backoff: base 1s, x2 per attempt, capped 60s, +/-50%
// jitter to avoid a thundering herd of clients retrying in lockstep.
const BACKOFF_BASE_MS = 1000
const BACKOFF_FACTOR = 2
const BACKOFF_CAP_MS = 60000
const BACKOFF_MAX_ATTEMPTS = 8

function backoffDelay(failedAttempt) {
  const raw = Math.min(BACKOFF_CAP_MS, BACKOFF_BASE_MS * BACKOFF_FACTOR ** failedAttempt)
  const jitter = raw * 0.5 * (Math.random() * 2 - 1)
  return Math.max(0, raw + jitter)
}

function readConfig() {
  if (registry.config) return registry.config
  const el = document.getElementById("solid-gcp-cable-config")
  registry.config = el ? JSON.parse(el.textContent) : {}
  return registry.config
}

function firebaseApp() {
  if (registry.app) return registry.app
  const config = readConfig()
  registry.app = getApps().length ? getApp() : initializeApp(config)
  return registry.app
}

function csrfToken() {
  const meta = document.querySelector("meta[name='csrf-token']")
  return meta ? meta.content : null
}

function scheduleTokenFetch() {
  if (registry.fetchScheduled) return
  registry.fetchScheduled = true
  queueMicrotask(() => {
    registry.fetchScheduled = false
    // The stream set just changed; the current session's token may not cover the
    // new streams, so force a fresh token and connect now (resetting backoff).
    registry.signedIn = false
    reconnect()
  })
}

async function fetchToken(signedNames) {
  const config = readConfig()
  const headers = { "Content-Type": "application/json" }
  const token = csrfToken()
  if (token) headers["X-CSRF-Token"] = token
  const response = await fetch(config.tokenPath, {
    method: "POST",
    headers,
    credentials: "same-origin",
    body: JSON.stringify({ signed_stream_names: signedNames })
  })
  if (!response.ok) throw new Error(`token fetch failed: ${response.status}`)
  const data = await response.json()
  return data.token
}

async function establishSession() {
  const app = firebaseApp()
  if (!registry.signedIn) {
    const token = await fetchToken(Array.from(registry.streams.keys()))
    await signInWithCustomToken(getAuth(app), token)
    registry.signedIn = true
  }
  registry.db = getFirestore(app)
}

// One connect attempt: (re)establish the session, then attach any missing
// listeners. Throws are caught here and turned into a backoff retry; onSnapshot
// runtime failures surface later via the error callback, not here.
async function connectAll() {
  if (registry.connecting) return
  if (registry.streams.size === 0) return
  registry.connecting = true
  try {
    await establishSession()
    for (const { doc: docPath } of registry.streams.values()) {
      if (registry.unsubscribes.has(docPath)) continue
      attachListener(docPath)
    }
    registry.attempt = 0
    registry.failed = false
  } catch (error) {
    registry.connecting = false
    scheduleRetry(error)
    return
  }
  registry.connecting = false
}

function scheduleRetry(error) {
  if (registry.retryTimer || registry.connecting) return
  registry.attempt += 1
  if (registry.attempt >= BACKOFF_MAX_ATTEMPTS) {
    registry.failed = true
    console.warn(`[solid-gcp-cable] giving up after ${registry.attempt} attempts`, error)
    document.dispatchEvent(
      new CustomEvent("solid-gcp-cable:failed", { detail: { error: String(error) } })
    )
    return
  }
  registry.retryTimer = setTimeout(() => {
    registry.retryTimer = null
    connectAll()
  }, backoffDelay(registry.attempt - 1))
}

// Fresh trigger (new streams, network resume): drop any pending backoff and try
// now with a clean attempt counter.
function reconnect() {
  if (registry.retryTimer) {
    clearTimeout(registry.retryTimer)
    registry.retryTimer = null
  }
  registry.attempt = 0
  registry.failed = false
  connectAll()
}

// Network came back / tab became visible again. Firestore reconnects its own
// transport; we only kick OUR token/attach retry if it's stalled (backing off
// or already gave up), and only when there's something to listen to.
function handleResume() {
  if (registry.streams.size === 0) return
  if (registry.failed || registry.retryTimer) reconnect()
}

function attachListener(docPath) {
  const [collection, docId] = docPath.split("/")
  const ref = doc(registry.db, collection, docId)
  let seenInitial = false

  const unsubscribe = onSnapshot(
    ref,
    (snapshot) => {
      if (!seenInitial) {
        // Skip the initial snapshot: it carries the doc's state *at listen
        // time* (which may already reflect earlier touches, esp. a doc that
        // persists across page loads). Only a bump that arrives AFTER this
        // point is a real "something changed, refresh" signal. Marking the doc
        // live here — once the initial snapshot has actually landed — is the
        // guarantee that any subsequent touch fires the callback again.
        seenInitial = true
        markListening(docPath)
        return
      }
      scheduleRefresh()
    },
    (error) => {
      if (isAuthError(error)) {
        // Auth/claims/rules changed (or token rejected): drop this listener,
        // force a fresh token + re-sign-in, then re-attach — but through the
        // backoff loop, so a persistent denial backs off instead of hot-looping.
        const unsub = registry.unsubscribes.get(docPath)
        if (unsub) unsub()
        registry.unsubscribes.delete(docPath)
        registry.live.delete(docPath)
        updateListeningMarker()
        registry.signedIn = false
        scheduleRetry(error)
      } else {
        // Transient (e.g. 'unavailable' while offline): Firestore keeps the
        // listener and resumes on its own — don't fight it.
        console.debug("[solid-gcp-cable] snapshot error (transient)", error)
      }
    }
  )
  registry.unsubscribes.set(docPath, unsubscribe)
}

// Announce that a doc is now being listened to (initial snapshot received, so
// later touches are guaranteed to surface). Tests wait on this before writing;
// app code can listen too. The attribute value is the count of live docs.
function markListening(docPath) {
  registry.live.add(docPath)
  updateListeningMarker()
  // A landed snapshot proves the whole chain works; clear any residual backoff.
  registry.attempt = 0
  registry.failed = false
  document.dispatchEvent(
    new CustomEvent("solid-gcp-cable:listening", {
      detail: { doc: docPath, docs: Array.from(registry.live) }
    })
  )
}

function updateListeningMarker() {
  document.documentElement.setAttribute(
    "data-solid-gcp-cable-listening",
    String(registry.live.size)
  )
}

function isAuthError(error) {
  const code = error && error.code ? String(error.code) : ""
  return code.includes("permission-denied") ||
    code.includes("unauthenticated") ||
    code.includes("token-expired")
}

function scheduleRefresh() {
  if (registry.refreshTimer) clearTimeout(registry.refreshTimer)
  registry.refreshTimer = setTimeout(() => {
    registry.refreshTimer = null
    if (window.Turbo?.session?.refresh) {
      window.Turbo.session.refresh(location.href)
    } else {
      document.dispatchEvent(new CustomEvent("solid-gcp-cable:refresh"))
    }
  }, 300)
}

// Network-resume hooks are page-global and live for the page's lifetime; they
// no-op unless a stream is registered and stalled (see handleResume).
window.addEventListener("online", handleResume)
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") handleResume()
})

export default class extends Controller {
  static values = { signedName: String, doc: String }

  connect() {
    const existing = registry.streams.get(this.signedNameValue)
    if (existing) {
      existing.count += 1
    } else {
      registry.streams.set(this.signedNameValue, { doc: this.docValue, count: 1 })
      scheduleTokenFetch()
    }
  }

  disconnect() {
    const entry = registry.streams.get(this.signedNameValue)
    if (!entry) return
    entry.count -= 1
    if (entry.count > 0) return

    registry.streams.delete(this.signedNameValue)
    const unsubscribe = registry.unsubscribes.get(entry.doc)
    if (unsubscribe) {
      unsubscribe()
      registry.unsubscribes.delete(entry.doc)
    }
    registry.live.delete(entry.doc)
    updateListeningMarker()

    // Last stream gone (page nav / morph removed it): cancel any in-flight retry
    // or refresh so a Turbo navigation doesn't leak a backoff loop, and reset so
    // a future connect starts clean.
    if (registry.streams.size === 0) {
      if (registry.retryTimer) {
        clearTimeout(registry.retryTimer)
        registry.retryTimer = null
      }
      if (registry.refreshTimer) {
        clearTimeout(registry.refreshTimer)
        registry.refreshTimer = null
      }
      registry.attempt = 0
      registry.failed = false
      registry.connecting = false
      registry.signedIn = false
    }
  }
}
