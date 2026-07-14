# frozen_string_literal: true

module SolidGcp
  # Executes a `command:` recurring entry, mirroring Solid Queue's behavior.
  class RecurringCommandJob < ActiveJob::Base
    def perform(command)
      # rubocop:disable Security/Eval
      eval(command, TOPLEVEL_BINDING) # standard:disable Security/Eval
      # rubocop:enable Security/Eval
    end
  end
end
