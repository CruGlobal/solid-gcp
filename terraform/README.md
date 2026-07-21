# solid_gcp — Terraform

The `solid_gcp` Terraform module lives in
[cru-terraform-modules](https://github.com/CruGlobal/cru-terraform-modules/tree/main/applications/solid-gcp)
(`applications/solid-gcp`) — see its README for what it creates, the gem↔module
contract (queue prefix, push route, OIDC identity, outputs → env vars), and
usage. It moved there from this repo per the devops-team convention that all
Cru terraform modules live in that repo (shared style/tflint/provider-version
enforcement, release tagging via release-please).

Because the gem and module now version independently, contract-affecting
changes must land in both places: note required module versions in this repo's
`CHANGELOG.md`, and gem compatibility in the module's README.

- **Real instantiation** (config + state) belongs in **cru-terraform**, sourcing:
  ```hcl
  source = "git@github.com:CruGlobal/cru-terraform-modules.git//applications/solid-gcp?ref=vX.Y.Z"
  ```
- **`sandbox/`** (this directory) is a hand-applied dev instantiation — local
  state, not managed by Atlantis.

## Sandbox

Per-developer values live in `terraform.tfvars` (gitignored) — copy
`terraform.tfvars.example` and fill in your own sandbox project. Cloning the
module source requires SSH access to the (private) cru-terraform-modules repo.

```sh
cd sandbox
terraform init
terraform apply
```

(`tofu` works as a drop-in for `terraform`.)

### First apply on a project with existing Firebase resources

Some cable resources 409 on create when they already exist — import first (see
the module README's "Adopting on a project with existing Firebase" for the full
list):

```sh
terraform import 'module.solid_gcp.google_firebase_project.cable[0]' <project-id>
terraform import 'module.solid_gcp.google_firestore_database.cable[0]' '(default)'
```

### Iterating on the module

For module changes, PR cru-terraform-modules. While developing, point the
sandbox `source` at your branch (`?ref=<branch>`) or a local clone
(`source = "../../..../cru-terraform-modules/applications/solid-gcp"`), then
restore the pinned tag before merging here.

## Notes

- The consuming app's deploy infra (Cloud Run service/job, Artifact Registry,
  image pipeline) is intentionally NOT part of the module — it belongs to the
  app (Flightdeck's lives in cru-terraform). The sandbox's `solid-gcp-dummy`
  Artifact Registry repo was created by hand via gcloud.
- Individual Cloud Scheduler jobs are owned by the gem
  (`rake solid_gcp:scheduler:sync`), not terraform — see the module README for
  the deploy-pipeline IAM that sync needs.
