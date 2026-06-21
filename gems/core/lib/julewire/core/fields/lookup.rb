# frozen_string_literal: true

module Julewire
  module Core
    module Fields
      module Lookup
        class << self
          def value(source, key)
            return unless source.respond_to?(:[])

            direct = source[key]
            return direct unless direct.nil?

            alternate_key(source, key)
          rescue StandardError
            nil
          end

          def blank?(value)
            value.nil? || (value.respond_to?(:empty?) && value.empty?)
          end

          private

          def alternate_key(source, key)
            case key
            when Symbol then source[key.name]
            when String then source[key.to_sym]
            end
          end
        end
      end
    end
  end
end
