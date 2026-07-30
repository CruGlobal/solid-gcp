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
  DEFAULT_INDEX = <<~JS
    import { application } from "controllers/application"
    import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"
    eagerLoadControllersFrom("controllers", application)
  JS

  test "registers the engine-served controller instead of copying one" do
    write_index

    run_generator

    assert_file INDEX do |content|
      assert_match(/^import SolidGcpCableController from "solid_gcp_cable_controller"$/, content)
      assert_match(/application\.register\("solid-gcp-cable", SolidGcpCableController\)/, content)
    end
    assert_no_file "app/javascript/controllers/solid_gcp_cable_controller.js"
    assert_file "firestore.rules"
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
    assert_file "firestore.rules"
  end

  private

  def write_index
    path = File.join(destination_root, INDEX)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, DEFAULT_INDEX)
  end
end
