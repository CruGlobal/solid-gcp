// Import and register all your controllers from the importmap via controllers/**/*_controller
import { application } from "controllers/application"
import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"
eagerLoadControllersFrom("controllers", application)

// Served by the solid_gcp engine (see its config/importmap.rb). Don't vendor a
// copy — it goes stale. Use `rails g solid_gcp:cable_install --vendor` only if you
// bundle JS with esbuild/webpack and need the file locally.
import SolidGcpCableController from "solid_gcp_cable_controller"
application.register("solid-gcp-cable", SolidGcpCableController)
