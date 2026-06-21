# frozen_string_literal: true

module Julewire
  module Core
    module Records
      # @api extension
      class Formatter
        def call(record)
          PublicProjection.new(record)
        end
      end
    end
  end
end
