# frozen_string_literal: true

require "concurrent/map"

module Julewire
  module Core
    module Diagnostics
      class IntegrationHealthStore
        def initialize
          @entries = Concurrent::Map.new
        end

        def record_failure(integration, error, **metadata)
          name = normalize_name(integration)
          metadata = { phase: :integration, integration: name }.merge(metadata)
          entry_for(name).record_failure(error, **metadata)
          nil
        end

        def record_success(integration)
          name = normalize_name(integration)
          entry_for(name).record_success
          nil
        end

        def health
          @entries.each_pair.with_object({}) do |(name, entry), snapshot|
            snapshot[name] = entry.snapshot
          end.freeze
        end

        def reset!
          @entries.clear
          nil
        end

        private

        def entry_for(name)
          @entries.compute_if_absent(name) { Health.new(counter_keys: []) }
        end

        def normalize_name(value)
          Core.normalize_name(value)
        rescue StandardError
          :unknown
        end
      end
    end
  end
end
