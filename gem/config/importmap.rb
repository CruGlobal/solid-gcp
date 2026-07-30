# Serves the cable Stimulus controller straight out of the gem, so apps don't
# vendor (and then silently stale) a copy of it. Pinned at the top level rather
# than under "controllers/" on purpose: names under that prefix are eager-loaded
# and registered by stimulus-loading, which would pull the firebase modules into
# every page of every app that installs the gem, cable or not. Registration is
# opt-in, one line in the app's controllers/index.js — `cable_install` adds it.
pin "solid_gcp_cable_controller", preload: false
