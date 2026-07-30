# frozen_string_literal: true

require "rails/engine"
require "active_job"
require "active_job/queue_adapters/solid_gcp_adapter"

module SolidGcp
  class Engine < ::Rails::Engine
    isolate_namespace SolidGcp

    # Expose SolidGcp.config as config.solid_gcp so `config.solid_gcp.mode = ...`
    # mutates the singleton directly.
    config.solid_gcp = SolidGcp.config

    initializer "solid_gcp.active_job_extensions" do
      ActiveSupport.on_load(:active_job) do
        SolidGcp.install_active_job_extensions(self)
      end
    end

    # Make cable view helpers available to host-app views (like turbo-rails).
    initializer "solid_gcp.cable.helpers" do
      ActiveSupport.on_load(:action_view) do
        include SolidGcp::CableHelper
      end
    end

    # Ship the cable Stimulus controller from the gem instead of having every app
    # vendor its own copy (which is how the client came to subscribe to the
    # "(default)" database long after the gem had learned about named ones).
    # Mirrors turbo-rails: engine importmap + the asset path it resolves against.
    initializer "solid_gcp.cable.importmap", before: "importmap" do |app|
      if app.config.respond_to?(:importmap)
        app.config.importmap.paths << Engine.root.join("config/importmap.rb")
        app.config.importmap.cache_sweepers << Engine.root.join("app/javascript")
      end
    end

    initializer "solid_gcp.cable.assets" do |app|
      if app.config.respond_to?(:assets)
        app.config.assets.paths << Engine.root.join("app/javascript")
      end
    end

    initializer "solid_gcp.connects_to" do
      config.after_initialize do
        # Record picks up connects_to lazily; nothing to do here unless configured.
      end
    end

    # server-only: dev stand-in for Cloud Scheduler ticks recurring.yml in-process.
    # Gated to `server` so consoles, rake tasks, and runners never tick.
    server do
      SolidGcp::LocalRecurring.start if SolidGcp.config.mode == :local
    end

    rake_tasks do
      load File.expand_path("../tasks/solid_gcp.rake", __dir__)
    end
  end
end
