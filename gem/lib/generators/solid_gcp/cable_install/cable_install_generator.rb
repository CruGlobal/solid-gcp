# frozen_string_literal: true

require "rails/generators"

module SolidGcp
  module Generators
    # `rails g solid_gcp:cable_install` registers the Stimulus controller the
    # engine serves and copies the Firestore security-rules template the
    # terraform module deploys.
    #
    # The controller itself is NOT copied by default. It used to be, and the copy
    # went stale: apps installed a client that subscribed to the "(default)"
    # Firestore database long after the gem had learned about named ones, with no
    # signal that anything was wrong. `--vendor` (for apps bundling JS with
    # esbuild/webpack, which can't import from a gem path) copies the canonical
    # file straight out of the engine — there is only ever one file to copy.
    class CableInstallGenerator < Rails::Generators::Base
      CONTROLLER_FILE = "solid_gcp_cable_controller.js"
      CONTROLLERS_INDEX = "app/javascript/controllers/index.js"
      CONTROLLER_IMPORT = 'import SolidGcpCableController from "solid_gcp_cable_controller"'

      desc "Registers the SolidGcp cable Stimulus controller and copies firestore.rules."

      class_option :vendor, type: :boolean, default: false,
        desc: "Copy the controller into app/javascript/controllers instead of importing it from the gem"

      def self.source_paths
        # The engine's app/javascript is a source path so --vendor copies the
        # shipped controller rather than a fork of it kept under templates/.
        [ File.expand_path("templates", __dir__), SolidGcp::Engine.root.join("app/javascript").to_s ]
      end

      def register_controller
        return copy_controller if options[:vendor]

        unless File.exist?(index_path)
          say_status :skip, "#{CONTROLLERS_INDEX} not found — register the controller yourself " \
                            "(or re-run with --vendor)", :yellow
          return
        end

        if File.read(index_path).include?(CONTROLLER_IMPORT)
          say_status :identical, CONTROLLERS_INDEX, :blue
          return
        end

        # Appended rather than injected mid-file: `import` is hoisted, so it works
        # wherever it lands, and appending survives whatever else the app has done
        # to its index.js.
        append_to_file CONTROLLERS_INDEX, <<~JS

          // Served by the solid_gcp engine (see its config/importmap.rb). Don't vendor a
          // copy — it goes stale. Use `rails g solid_gcp:cable_install --vendor` only if you
          // bundle JS with esbuild/webpack and need the file locally.
          #{CONTROLLER_IMPORT}
          application.register("solid-gcp-cable", SolidGcpCableController)
        JS
      end

      def copy_rules
        copy_file "firestore.rules", "firestore.rules"
      end

      private

      def index_path
        File.join(destination_root, CONTROLLERS_INDEX)
      end

      def copy_controller
        copy_file CONTROLLER_FILE, "app/javascript/controllers/#{CONTROLLER_FILE}"
      end
    end
  end
end
