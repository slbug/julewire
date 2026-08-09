# frozen_string_literal: true

require "concurrent/map"

module Julewire
  module Core
    module Integration
      module ForkHooks
        Entry = Data.define(:integration, :component, :callback)
        private_constant :Entry

        @entries = Concurrent::Map.new

        class << self
          def register(integration, component:, &callback)
            raise ArgumentError, "block required" unless callback

            HookNames.validate!(integration, name: :integration)
            HookNames.validate!(component, name: :component)
            register_entry(integration, component, callback)
          end

          def run
            snapshot = entries.values
            snapshot.each { run_entry(it) }
          end

          private

          attr_reader :entries

          def register_entry(name, component, callback)
            entries[[name, component]] = Entry.new(name, component, callback)
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
          end
        end
      end
    end
  end
end
