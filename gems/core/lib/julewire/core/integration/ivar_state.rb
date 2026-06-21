# frozen_string_literal: true

module Julewire
  module Core
    module Integration
      # @api integration_spi
      class IvarState
        def initialize(marker)
          @marker = marker
        end

        def fetch(owner)
          return unless owner.respond_to?(:instance_variable_get)

          owner.instance_variable_get(@marker)
        rescue StandardError
          nil
        end

        def store(owner, value)
          return value unless owner.respond_to?(:instance_variable_set)

          owner.instance_variable_set(@marker, value)
          value
        rescue StandardError
          value
        end

        def fetch_or_store(owner)
          existing = fetch(owner)
          return existing if existing

          store(owner, yield)
        end
      end
    end
  end
end
