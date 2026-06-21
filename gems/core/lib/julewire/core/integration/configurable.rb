# frozen_string_literal: true

module Julewire
  module Core
    module Integration
      # @api integration_spi
      module Configurable
        def configurable_with(&configuration_class)
          raise ArgumentError, "configuration class block required" unless configuration_class

          @julewire_configuration_class = configuration_class
        end

        def config
          @config ||= build_config
        end

        def config=(configuration)
          validate_config!(configuration)
          @config = configuration
        end

        def configure
          raise ArgumentError, "#{name}.configure requires a block" unless block_given?

          yield config
          config
        end

        def reset!
          @config = build_config
        end

        private

        def build_config
          configuration_class.new
        end

        def validate_config!(configuration)
          return if configuration.is_a?(configuration_class)

          raise TypeError, "expected #{configuration_class.name}"
        end

        def configuration_class
          @julewire_configuration_class.call
        end
      end
    end
  end
end
