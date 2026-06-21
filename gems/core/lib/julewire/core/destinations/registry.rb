# frozen_string_literal: true

module Julewire
  module Core
    module Destinations
      class Registry
        DESTINATION_METHODS = %i[name emit flush close health].freeze
        private_constant :DESTINATION_METHODS

        class << self
          def validate!(destination)
            DESTINATION_METHODS.each do |method_name|
              unless destination.respond_to?(method_name)
                raise ArgumentError, "destination must respond to ##{method_name}"
              end
            end

            destination
          end
        end

        def initialize(definitions = [])
          @definitions = definitions.map { copy_definition(it) }
        end

        def use(name, **)
          definition = Definition.new(name, **)
          raise ArgumentError, "destination #{definition.name.inspect} is already configured" if key?(definition.name)

          @definitions << definition
          self
        end

        def add(destination)
          self.class.validate!(destination)
          raise ArgumentError, "destination #{destination.name.inspect} is already configured" if key?(destination.name)

          @definitions << destination
          self
        end

        def clear
          @definitions.clear
          self
        end

        def empty? = @definitions.empty?

        def build(defaults:)
          output_identities = {}.compare_by_identity
          @definitions.map do |definition|
            if definition.is_a?(Definition)
              definition.build(defaults: defaults, output_identities: output_identities)
            else
              definition
            end
          end.freeze
        end

        def copy
          self.class.new(@definitions)
        end

        def freeze
          @definitions.freeze
          super
        end

        private

        def key?(name)
          @definitions.any? { it.name == name }
        end

        def copy_definition(definition)
          definition.respond_to?(:copy) ? definition.copy : definition
        end
      end
    end
  end
end
