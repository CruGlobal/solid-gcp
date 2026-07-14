# ---------------------------------------------------------------------------
# Cable component (SolidGcp::Cable) — Firestore realtime "dirty bit" streams
# ---------------------------------------------------------------------------
# All resources here are gated on var.enable_cable (default false) so a
# queue-only adopter provisions none of this. Firebase / Identity Platform /
# Firestore rules resources need the google-beta provider (wired in versions.tf;
# consumers must pass a configured google-beta provider — see sandbox/).
#
# Flaky-apply notes (see terraform/README.md "Sandbox first-apply" for commands):
#   - google_firebase_project 409s if the project is already Firebase-enabled;
#     import it (import id = project id) rather than create.
#   - google_firestore_database 409s if "(default)" already exists; import it
#     (import id = "(default)").
#   - google_identity_platform_config 409s ("CONFIGURATION_EXISTS") if Identity
#     Platform / Firebase Auth was already initialized on the project; import it
#     (import id = project id) then re-apply.

locals {
  # Firestore location: defaults to var.region. Note multi-region Firestore ids
  # (e.g. "nam5", "eur3") differ from Cloud Run regions; single-region ids like
  # "us-central1" are valid Firestore locations and fine for the sandbox.
  firestore_location = coalesce(var.firestore_location, var.region)
}

# ---------------------------------------------------------------------------
# APIs (cable only)
# ---------------------------------------------------------------------------
resource "google_project_service" "cable_apis" {
  for_each = var.enable_cable ? toset([
    "firestore.googleapis.com",
    "firebase.googleapis.com",
    "identitytoolkit.googleapis.com",
    "firebaserules.googleapis.com",
    "iamcredentials.googleapis.com",
  ]) : toset([])

  project = var.project_id
  service = each.value

  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# Firestore database + TTL policy
# ---------------------------------------------------------------------------
# Native-mode "(default)" database. One doc per stream lives under
# var.cable_collection; the app sets expires_at, and the TTL policy below reaps
# expired stream docs.
resource "google_firestore_database" "cable" {
  count = var.enable_cable ? 1 : 0

  project     = var.project_id
  name        = "(default)"
  location_id = local.firestore_location
  type        = "FIRESTORE_NATIVE"

  depends_on = [google_project_service.cable_apis]
}

# TTL policy on expires_at for the streams collection. Firestore reaps docs
# whose expires_at is in the past (best-effort, within ~72h of expiry).
resource "google_firestore_field" "cable_ttl" {
  count = var.enable_cable ? 1 : 0

  project    = var.project_id
  database   = google_firestore_database.cable[0].name
  collection = var.cable_collection
  field      = "expires_at"

  ttl_config {}
}

# ---------------------------------------------------------------------------
# Firebase project + web app (client config for the browser SDK)
# ---------------------------------------------------------------------------
resource "google_firebase_project" "cable" {
  provider = google-beta
  count    = var.enable_cable ? 1 : 0

  project = var.project_id

  depends_on = [google_project_service.cable_apis]
}

resource "google_firebase_web_app" "cable" {
  provider = google-beta
  count    = var.enable_cable ? 1 : 0

  project      = var.project_id
  display_name = var.firebase_web_app_display_name

  # No deletion_policy: default keeps the web app on destroy (add "DELETE" if you
  # want terraform to remove it). Web apps are cheap and safe to leave.

  depends_on = [google_firebase_project.cable]
}

# Web SDK config (apiKey / authDomain / ...) surfaced to the app's
# firebase_web_config setting via the module output.
data "google_firebase_web_app_config" "cable" {
  provider = google-beta
  count    = var.enable_cable ? 1 : 0

  project    = var.project_id
  web_app_id = google_firebase_web_app.cable[0].app_id
}

# ---------------------------------------------------------------------------
# Identity Platform (Firebase Auth) — required so custom tokens work
# ---------------------------------------------------------------------------
# Enables Identity Toolkit / Firebase Auth on the project. Rails mints Firebase
# custom tokens (signed via IAM signBlob) and the browser exchanges them via
# signInWithCustomToken. See flaky-apply note at top of file re: 409 on re-init.
resource "google_identity_platform_config" "cable" {
  provider = google-beta
  count    = var.enable_cable ? 1 : 0

  project = var.project_id

  depends_on = [
    google_project_service.cable_apis,
    google_firebase_project.cable,
  ]
}

# ---------------------------------------------------------------------------
# Firestore security rules (ruleset + release)
# ---------------------------------------------------------------------------
# Rules allow only doc-level `get` on the streams collection, and only for docs
# whose id is present in the caller's token `sgs` claim. No writes, no list.
# Collection name is parameterized to match var.cable_collection.
resource "google_firebaserules_ruleset" "cable" {
  provider = google-beta
  count    = var.enable_cable ? 1 : 0

  project = var.project_id

  source {
    files {
      name    = "firestore.rules"
      content = templatefile("${path.module}/firestore.rules.tftpl", { collection = var.cable_collection })
    }
  }

  depends_on = [google_firestore_database.cable]
}

resource "google_firebaserules_release" "cable" {
  provider = google-beta
  count    = var.enable_cable ? 1 : 0

  project = var.project_id
  # "cloud.firestore" targets the (default) database. A named database would be
  # "cloud.firestore/<database>".
  name         = "cloud.firestore"
  ruleset_name = google_firebaserules_ruleset.cable[0].name
}

# ---------------------------------------------------------------------------
# Runtime SA IAM for cable
# ---------------------------------------------------------------------------
# Reuses the app runtime SA (var.app_service_account_email — the SA the Cloud
# Run service runs as). It reads/writes stream docs (datastore.user) and signs
# its own Firebase custom tokens via IAM signBlob (serviceAccountTokenCreator on
# itself).
resource "google_project_iam_member" "cable_datastore_user" {
  count = var.enable_cable ? 1 : 0

  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${var.app_service_account_email}"
}

# serviceAccountTokenCreator granted to the SA *on itself* → lets it call
# iamcredentials signBlob to RS256-sign Firebase custom tokens (no key file).
resource "google_service_account_iam_member" "cable_token_creator_self" {
  count = var.enable_cable ? 1 : 0

  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.app_service_account_email}"
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${var.app_service_account_email}"
}
