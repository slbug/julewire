# frozen_string_literal: true

require "concurrent/map"

module Julewire
  module Core
    module Integration
      module BeforeForkHooks
        @entries = Concurrent::Map.new

        class << self
          def register(integration, component:, &callback)
            raise ArgumentError, "block required" unless callback

            HookNames.validate!(integration, name: :integration)
            HookNames.validate!(component, name: :component)
            entries[[integration, component]] = callback
          end

          def run
            entries.each_value(&:call)
            nil
          end

          private

          attr_reader :entries
        end
      end
    end
  end
end
