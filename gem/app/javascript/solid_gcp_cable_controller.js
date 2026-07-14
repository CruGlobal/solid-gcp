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
  config: null
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
    connectAll()
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

async function connectAll(retried = false) {
  const signedNames = Array.from(registry.streams.keys())
  if (signedNames.length === 0) return

  try {
    const token = await fetchToken(signedNames)
    const app = firebaseApp()
    await signInWithCustomToken(getAuth(app), token)
    registry.db = getFirestore(app)

    for (const { doc: docPath } of registry.streams.values()) {
      if (registry.unsubscribes.has(docPath)) continue
      attachListener(docPath)
    }
  } catch (error) {
    if (!retried && isAuthError(error)) return connectAll(true)
    console.error("[solid-gcp-cable] connect failed", error)
  }
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
    async (error) => {
      if (isAuthError(error)) {
        // Token expired (~1h) or permission changed: re-auth and re-attach once.
        unsubscribe()
        registry.unsubscribes.delete(docPath)
        registry.live.delete(docPath)
        await connectAll(true)
      } else {
        console.error("[solid-gcp-cable] snapshot error", error)
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
  document.documentElement.setAttribute(
    "data-solid-gcp-cable-listening",
    String(registry.live.size)
  )
  document.dispatchEvent(
    new CustomEvent("solid-gcp-cable:listening", {
      detail: { doc: docPath, docs: Array.from(registry.live) }
    })
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
    document.documentElement.setAttribute(
      "data-solid-gcp-cable-listening",
      String(registry.live.size)
    )
  }
}
