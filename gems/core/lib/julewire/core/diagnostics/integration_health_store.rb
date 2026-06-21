# frozen_string_literal: true

module Julewire
  module Core
    module Diagnostics
      class IntegrationHealthStore
        def initialize
          @mutex = Mutex.new
          @entries = {}
        end

        def record_failure(integration, error, **metadata)
          name = normalize_name(integration)
          metadata = { phase: :integration, integration: name }.merge(metadata)
          @mutex.synchronize do
            entry_for(name).record_failure(error, **metadata)
          end
          nil
        rescue StandardError
          nil
        end

        def record_success(integration)
          name = normalize_name(integration)
          @mutex.synchronize do
            entry_for(name).record_success
          end
          nil
        rescue StandardError
          nil
        end

        def health
          @mutex.synchronize do
            @entries.to_h { |name, entry| [name, entry.snapshot] }.freeze
          end
        end

        def reset!
          @mutex.synchronize { @entries.clear }
          nil
        end

        def after_fork!
          @mutex = Mutex.new
          @entries = {}
          nil
        end

        private

        def entry_for(name)
          @entries[name] ||= Health.new(counter_keys: [:failures])
        end

        def normalize_name(value)
          Core.normalize_name(value, name: :integration)
        rescue StandardError
          :unknown
        end
      end
    end
  end
end
