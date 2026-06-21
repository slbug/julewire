# frozen_string_literal: true

module Julewire
  module Core
    module Destinations
      @factories = {}

      class << self
        def register(kind, &factory)
          raise ArgumentError, "destination factory block required" unless factory

          @factories[normalize_name(kind)] = factory
          nil
        end

        # Private testing seam for `Julewire::Testing.unregister_destination`.
        def unregister(kind)
          @factories.delete(normalize_name(kind))
          nil
        end
        private :unregister

        def factory_for(kind)
          @factories[normalize_name(kind)]
        end

        def normalize_name(value)
          Core.normalize_name(value, name: "destination name")
        end
      end
    end
  end
end
