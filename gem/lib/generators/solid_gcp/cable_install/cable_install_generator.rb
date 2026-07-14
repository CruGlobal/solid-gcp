# frozen_string_literal: true

require "rails/generators"

module SolidGcp
  module Generators
    # `rails g solid_gcp:cable_install` copies the Stimulus controller and a
    # Firestore security-rules template the terraform module deploys.
    class CableInstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      def copy_controller
        copy_file "solid_gcp_cable_controller.js",
          "app/javascript/controllers/solid_gcp_cable_controller.js"
      end

      def copy_rules
        copy_file "firestore.rules", "firestore.rules"
      end
    end
  end
end