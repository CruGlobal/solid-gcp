# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"

module SolidGcp
  module Generators
    # `rails g solid_gcp:install` copies the migration creating the three tables.
    class InstallGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      def self.next_migration_number(dirname)
        next_migration_number = current_migration_number(dirname) + 1
        ActiveRecord::Migration.next_migration_number(next_migration_number)
      end

      def create_migration_file
        migration_template(
          "create_solid_gcp_tables.rb.tt",
          "db/migrate/create_solid_gcp_tables.rb"
        )
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
