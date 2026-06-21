# frozen_string_literal: true

module Julewire
  module Core
    module Integration
      module ForkHooks
        Entry = Data.define(:integration, :component, :callback)
        private_constant :Entry

        @mutex = Mutex.new
        @entries = {}

        class << self
          def register(integration, component:, &callback)
            raise ArgumentError, "block required" unless callback

            name = integration_name(integration)
            component = component.to_sym
            register_entry(name, component, callback)
          end

          def run
            snapshot = mutex.synchronize { entries.values }
            snapshot.each { run_entry(it) }
            nil
          end

          def after_fork!
            @mutex = Mutex.new
            nil
          end

          def reset!
            mutex.synchronize { entries.clear }
            nil
          end

          private

          attr_reader :entries, :mutex

          def register_entry(name, component, callback)
            mutex.synchronize do
              entries[[name, component]] = Entry.new(name, component, callback)
            end
            nil
          rescue StandardError => e
            Diagnostics::ProcessIntegrationHealth.record_failure(
              name,
              e,
              action: :register_after_fork,
              component: component
            )
            nil
          end

          def run_entry(entry)
            entry.callback.call
          rescue StandardError => e
            Diagnostics::ProcessIntegrationHealth.record_failure(
              entry.integration,
              e,
              action: :after_fork,
              component: entry.component
            )
            nil
          end

          def integration_name(value)
            name = value.to_s
            raise ArgumentError, "integration name is required" if name.empty?

            name.to_sym
          end
        end
      end
    end
  end
end
