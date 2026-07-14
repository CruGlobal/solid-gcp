require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

# Rails 8.1's ActiveJob::QueueAdapters.lookup resolves `:solid_gcp` via bare
# const_get with no auto-require, so the adapter constant must already be
# defined. The gem's engine doesn't require it (see notes in dummy/README.md),
# so we require it explicitly before `queue_adapter = :solid_gcp` is applied.
require "active_job/queue_adapters/solid_gcp_adapter"

module Dummy
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Solid GCP is the Active Job backend under test. Per-environment mode
    # (:local / :test / :cloud_tasks) is set in config/environments/*.
    config.active_job.queue_adapter = :solid_gcp
  end
end
