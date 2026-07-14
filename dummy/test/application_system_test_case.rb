require "test_helper"

# Headless Chrome via Selenium. Only the cable E2E uses this today; it is
# skipped unless SOLID_GCP_CABLE_E2E is set, so the default suite never launches
# a browser.
class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 900 ]
end
