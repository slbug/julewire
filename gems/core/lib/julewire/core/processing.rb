# frozen_string_literal: true

module Julewire
  module Core
    module Processing
      @factories = {}

      class << self
        def register(kind, &factory)
          raise ArgumentError, "processor factory block required" unless factory

          @factories[normalize_kind(kind)] = factory
          nil
        end

        def build(kind, ...)
          factory = factory_for(kind)
          raise ArgumentError, "unknown processor kind #{kind.inspect}" unless factory

          factory.call(...)
        end

        def factory_for(kind)
          @factories[normalize_kind(kind)]
        end

        private

        def normalize_kind(kind)
          raise ArgumentError, "processor kind is required" if kind.nil?
          raise ArgumentError, "processor kind must respond to #to_sym" unless kind.respond_to?(:to_sym)

          name = kind.to_sym
          raise ArgumentError, "processor kind cannot be empty" if name.name.empty?

          name
        end
      end
    end
  end
end
