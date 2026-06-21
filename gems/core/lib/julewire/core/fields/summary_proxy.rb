# frozen_string_literal: true

module Julewire
  module Core
    module Fields
      class SummaryProxy
        def initialize(store)
          @store = store
        end

        def add(fields = nil, **keyword_fields)
          current_scope.add_summary(summary_fields(fields, keyword_fields), owned: true)
          self
        end

        def add_attributes(fields = nil, **keyword_fields)
          current_scope.add_summary_attributes(summary_fields(fields, keyword_fields), owned: true)
          self
        end

        def increment_attribute(*path, by: 1)
          current_scope.increment_summary_attribute(path, by: by)
          self
        end

        def increment(key, by: 1)
          current_scope.increment_summary(key, by: by)
          self
        end

        def measure(key, &)
          raise ArgumentError, "block required" unless block_given?

          current_scope.measure_summary(key, &)
        end

        def measure_start(key)
          current_scope.measure_summary_start(key)
        end

        def append(key, value)
          current_scope.append_summary(key, value)
          self
        end

        def active?
          @store.current_scope?
        end

        private

        def current_scope
          @store.current_scope || raise(Execution::NoCurrentError, "summary data requires a current execution scope")
        end

        def summary_fields(fields, keyword_fields)
          FieldSet.coerce(fields, keyword_fields, invalid: :wrap)
        end
      end
    end
  end
end
