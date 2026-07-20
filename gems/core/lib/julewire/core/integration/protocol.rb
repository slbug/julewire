# frozen_string_literal: true

module Julewire
  module Core
    module Integration
      # @api integration_spi
      module Protocol
        class << self
          def validate_symbol_keys(value)
            Serialization::DeepFreeze.validate_symbol_keys(value)
          end

          def validate_symbol_hash(value)
            Serialization::DeepFreeze.validate_symbol_hash(value)
          end
        end
      end
    end
  end
end
