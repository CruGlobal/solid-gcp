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
      IMPORTMAP = "config/importmap.rb"

      # The controller imports these three; they are pinned in the app rather than
      # in the engine so the app owns the Firebase SDK version. This is the version
      # the gem's own suite runs against — bump it in your importmap when you like.
      FIREBASE_VERSION = "12.0.0"
      FIREBASE_MODULES = %w[app auth firestore].freeze

      desc "Wires up the SolidGcp cable Stimulus controller (registration + firebase pins)."

      class_option :vendor, type: :boolean, default: false,
        desc: "Copy the controller into app/javascript/controllers instead of importing it from the gem"

      class_option :rules, type: :boolean, default: false,
        desc: "Write a firestore.rules starter (skip it when terraform owns the ruleset, as the " \
              "cru-terraform solid-gcp module does)"

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

      # Without these the registered controller's `import ... from "firebase/app"`
      # doesn't resolve and the module throws on load — a registration alone is not
      # a working install.
      def pin_firebase
        unless File.exist?(importmap_path)
          say_status :skip, "#{IMPORTMAP} not found — pin the firebase modules however you " \
                            "bundle JS (firebase/app, firebase/auth, firebase/firestore)", :yellow
          return
        end

        if File.read(importmap_path).include?('pin "firebase/app"')
          say_status :identical, IMPORTMAP, :blue
          return
        end

        append_to_file IMPORTMAP, <<~RUBY

          # Firebase ESM builds from the gstatic CDN, imported by the SolidGcp::Cable
          # Stimulus controller. Self-contained modules; preload: false keeps them out of
          # the modulepreload set (they load with the controller). Bump the version freely
          # — the app owns the Firebase SDK version, not the gem.
          #{FIREBASE_MODULES.map { |mod| pin_line(mod) }.join("\n")}
        RUBY
      end

      # Opt-in: for apps on the cru-terraform solid-gcp module, terraform renders and
      # releases this ruleset, so a repo-root copy is a second source of truth nobody
      # deploys — and re-running this generator (the supported upgrade path) used to
      # keep re-adding the file such apps had deliberately deleted.
      def copy_rules
        unless options[:rules]
          say_status :skip, "firestore.rules — terraform renders the ruleset; pass --rules for " \
                            "a starter if your app deploys it itself", :blue
          return
        end

        copy_file "firestore.rules", "firestore.rules"
      end

      private

      def pin_line(mod)
        %(pin "firebase/#{mod}", to: "https://www.gstatic.com/firebasejs/) +
          %(#{FIREBASE_VERSION}/firebase-#{mod}.js", preload: false)
      end

      def index_path
        File.join(destination_root, CONTROLLERS_INDEX)
      end

      def importmap_path
        File.join(destination_root, IMPORTMAP)
      end

      def copy_controller
        copy_file CONTROLLER_FILE, "app/javascript/controllers/#{CONTROLLER_FILE}"
      end
    end
  end
end
