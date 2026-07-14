# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"

# Firebase ESM builds from the gstatic CDN, consumed by the SolidGcp::Cable
# Stimulus controller. Self-contained modules; lazy (preload: false) since the
# cable client only loads them when a stream element is on the page.
pin "firebase/app", to: "https://www.gstatic.com/firebasejs/12.0.0/firebase-app.js", preload: false
pin "firebase/auth", to: "https://www.gstatic.com/firebasejs/12.0.0/firebase-auth.js", preload: false
pin "firebase/firestore", to: "https://www.gstatic.com/firebasejs/12.0.0/firebase-firestore.js", preload: false
