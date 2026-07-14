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

    initializer "solid_gcp.connects_to" do
      config.after_initialize do
        # Record picks up connects_to lazily; nothing to do here unless configured.
      end
    end

    rake_tasks do
      load File.expand_path("../tasks/solid_gcp.rake", __dir__)
    end
  end
end
