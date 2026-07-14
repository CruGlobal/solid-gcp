# frozen_string_literal: true

require "active_support"
require "active_support/core_ext"

require "solid_gcp/version"

module SolidGcp
  # Path the engine is expected to be mounted at in the consumer app.
  MOUNT_PATH = "/solid_gcp"

  class Error < StandardError; end

  # Infra not ready (DB waking, deploy race). Maps to 503 so Cloud Tasks retries.
  class NotReady < Error; end

  # Misconfiguration detected at boot (e.g. Solid Queue also loaded).
  class ConfigurationError < Error; end
end

require "solid_gcp/configuration"
require "solid_gcp/envelope"
require "solid_gcp/concurrency_controls"
require "solid_gcp/execution_mode"
require "solid_gcp/oidc_verifier"
require "solid_gcp/dispatcher"
require "solid_gcp/receiver"
require "solid_gcp/sweep"
require "solid_gcp/sweep_scheduler"
require "solid_gcp/recurring"
require "solid_gcp/scheduler_sync"
require "solid_gcp/cloud_run_job_launcher"
require "solid_gcp/backends/test"
require "solid_gcp/backends/local"
require "solid_gcp/backends/cloud_tasks"
require "solid_gcp/testing"
require "solid_gcp/cable"

module SolidGcp
  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    # Included into ActiveJob::Base by the engine. Refuses to load next to Solid Queue.
    def install_active_job_extensions(base)
      if base.respond_to?(:limits_concurrency)
        raise ConfigurationError,
          "ActiveJob::Base already responds to :limits_concurrency. " \
          "SolidGcp cannot be loaded alongside Solid Queue; remove one of them."
      end
      base.include(ConcurrencyControls)
      base.include(ExecutionMode)
    end

    def oidc_verifier
      @oidc_verifier ||= OidcVerifier.new
    end

    attr_writer :oidc_verifier
  end
end

require "solid_gcp/engine" if defined?(Rails::Engine)
