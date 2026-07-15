# frozen_string_literal: true

require_relative "lib/solid_gcp/version"

Gem::Specification.new do |spec|
  spec.name        = "solid_gcp"
  spec.version     = SolidGcp::VERSION
  spec.authors     = ["Cru"]
  spec.email       = ["matt.drees@cru.org"]
  spec.summary     = "GCP-centric Active Job backend (Cloud Tasks push + Postgres concurrency)."
  spec.description = "Replaces Solid Queue with Cloud Tasks push delivery, Postgres-backed " \
                     "concurrency semaphores, Cloud Run Jobs execution mode, and Cloud Scheduler recurring."
  spec.homepage    = "https://github.com/CruGlobal/solid-gcp"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["source_code_uri"] = "https://github.com/CruGlobal/solid-gcp"
  spec.metadata["changelog_uri"]   = "https://github.com/CruGlobal/solid-gcp/blob/main/CHANGELOG.md"
  # Not published to rubygems.org — consumed via Bundler git source pinned to a
  # tag. The bogus push host makes an accidental `gem push` fail.
  spec.metadata["allowed_push_host"] = "https://not-published.invalid"

  spec.files = Dir[
    "lib/**/*", "app/**/*", "config/**/*", "README.md"
  ]
  spec.require_paths = ["lib"]

  spec.add_dependency "rails", ">= 7.1"
  spec.add_dependency "google-cloud-tasks", ">= 2.0"
  spec.add_dependency "google-cloud-run-v2", ">= 0.10"
  spec.add_dependency "google-cloud-scheduler", ">= 2.0"
  spec.add_dependency "googleauth", ">= 1.0"
  spec.add_dependency "fugit", ">= 1.8"

  spec.add_development_dependency "minitest", ">= 5.0"
  spec.add_development_dependency "sqlite3", ">= 1.6"
  spec.add_development_dependency "rake", ">= 13.0"
end
