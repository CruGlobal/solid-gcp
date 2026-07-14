# frozen_string_literal: true

module SolidGcp
  class Record < ActiveRecord::Base
    self.abstract_class = true

    if SolidGcp.config.connects_to
      connects_to(**SolidGcp.config.connects_to)
    end
  end
end
