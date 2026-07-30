# frozen_string_literal: true

require "test_helper"
require "rails/generators"
require "rails/generators/test_case"
require "generators/solid_gcp/cable_install/cable_install_generator"

# The generator used to copy a fork of the Stimulus controller kept under
# templates/, and the fork went stale (subscribing to the "(default)" Firestore
# database long after the gem supported named ones). These pin the two things
# that keep that from recurring: by default nothing is copied, and --vendor
# copies the file the engine actually serves.
class CableInstallGeneratorTest < Rails::Generators::TestCase
  tests SolidGcp::Generators::CableInstallGenerator
  destination File.join(Dir.tmpdir, "solid_gcp_cable_install_generator")
  setup :prepare_destination

  CANONICAL = SolidGcp::Engine.root.join("app/javascript/solid_gcp_cable_controller.js")
  INDEX = "app/javascript/controllers/index.js"
  IMPORTMAP = "config/importmap.rb"
  DEFAULT_INDEX = <<~JS
    import { application } from "controllers/application"
    import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"
    eagerLoadControllersFrom("controllers", application)
  JS
  DEFAULT_IMPORTMAP = <<~RUBY
    pin "application"
    pin_all_from "app/javascript/controllers", under: "controllers"
  RUBY

  test "registers the engine-served controller instead of copying one" do
    write_index

    run_generator

    assert_file INDEX do |content|
      assert_match(/^import SolidGcpCableController from "solid_gcp_cable_controller"$/, content)
      assert_match(/application\.register\("solid-gcp-cable", SolidGcpCableController\)/, content)
    end
    assert_no_file "app/javascript/controllers/solid_gcp_cable_controller.js"
  end

  # A registered controller whose `import ... from "firebase/app"` doesn't resolve
  # throws on load, so pinning the three modules is part of installing, not a doc
  # footnote. Pinned in the app (not the engine) so the app owns the SDK version.
  test "pins the firebase modules the controller imports" do
    write_index
    write_importmap

    run_generator

    assert_file IMPORTMAP do |content|
      %w[app auth firestore].each do |mod|
        assert_match(
          %r{^pin "firebase/#{mod}", to: "https://www\.gstatic\.com/firebasejs/\d+\.\d+\.\d+/firebase-#{mod}\.js", preload: false$},
          content
        )
      end
    end
  end

  test "re-running does not pin firebase twice" do
    write_index
    write_importmap

    run_generator
    run_generator

    assert_equal 1, File.read(File.join(destination_root, IMPORTMAP)).scan(/pin "firebase\/app"/).length
  end

  test "without an importmap it says so rather than failing" do
    write_index

    output = run_generator

    assert_match(/#{Regexp.escape(IMPORTMAP)} not found/, output)
    assert_file INDEX do |content|
      assert_match(/application\.register/, content)
    end
  end

  # For apps on the cru-terraform solid-gcp module, terraform renders and releases
  # the ruleset; re-running the generator used to keep re-adding a file those apps
  # deleted on purpose.
  test "no firestore.rules unless asked" do
    write_index

    output = run_generator

    assert_no_file "firestore.rules"
    assert_match(/terraform renders the ruleset/, output)
  end

  test "--rules writes the starter" do
    write_index

    run_generator [ "--rules" ]

    assert_file "firestore.rules" do |content|
      assert_match(/solid_gcp_streams/, content)
    end
  end

  test "re-running does not register the controller twice" do
    write_index

    run_generator
    run_generator

    assert_equal 1, File.read(File.join(destination_root, INDEX)).scan(/application\.register/).length
  end

  test "--vendor copies the controller the engine serves, byte for byte" do
    write_index

    run_generator [ "--vendor" ]

    assert_file "app/javascript/controllers/solid_gcp_cable_controller.js" do |content|
      assert_equal File.read(CANONICAL), content
    end
    # Vendored files land under controllers/, where stimulus-loading finds them.
    assert_file INDEX do |content|
      refute_match(/application\.register/, content)
    end
  end

  test "without a controllers index it says so rather than failing" do
    output = run_generator

    assert_match(/#{Regexp.escape(INDEX)} not found/, output)
    assert_no_file "app/javascript/controllers/solid_gcp_cable_controller.js"
  end

  private

  def write_index
    write_destination_file(INDEX, DEFAULT_INDEX)
  end

  def write_importmap
    write_destination_file(IMPORTMAP, DEFAULT_IMPORTMAP)
  end

  def write_destination_file(relative, content)
    path = File.join(destination_root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
end
