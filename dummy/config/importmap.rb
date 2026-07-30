# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"

# Firebase ESM builds from the gstatic CDN, imported by the SolidGcp::Cable
# Stimulus controller. Self-contained modules; preload: false keeps them out of
# the modulepreload set (they load with the controller). Bump the version freely
# — the app owns the Firebase SDK version, not the gem.
pin "firebase/app", to: "https://www.gstatic.com/firebasejs/12.0.0/firebase-app.js", preload: false
pin "firebase/auth", to: "https://www.gstatic.com/firebasejs/12.0.0/firebase-auth.js", preload: false
pin "firebase/firestore", to: "https://www.gstatic.com/firebasejs/12.0.0/firebase-firestore.js", preload: false
