# frozen_string_literal: true

require "test_helper"
require "rails/generators"
require "rails/generators/test_case"
require "generators/solid_gcp/install/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests SolidGcp::Generators::InstallGenerator
  destination File.join(Dir.tmpdir, "solid_gcp_install_generator")
  setup :prepare_destination

  test "copies the tolerant, env-driven initializer" do
    run_generator

    assert_file "config/initializers/solid_gcp.rb" do |content|
      assert_match(/config\.solid_gcp\.project\s*=\s*ENV\["SOLID_GCP_PROJECT"\]/, content)
      # tolerant: ENV[...] not ENV.fetch on the required keys
      refute_match(/ENV\.fetch\("SOLID_GCP_PROJECT"\)/, content)
    end
  end

  test "still copies the migration" do
    run_generator

    assert_migration "db/migrate/create_solid_gcp_tables.rb"
  end
end
