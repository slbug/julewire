# frozen_string_literal: true

module Julewire
  module Core
    module Integration
      module HookNames
        class << self
          def validate!(value, name:)
            raise TypeError, "#{name} must be a Symbol" unless value.instance_of?(Symbol)
            raise ArgumentError, "#{name} is required" if value == :""
          end
        end
      end
    end
  end
end
