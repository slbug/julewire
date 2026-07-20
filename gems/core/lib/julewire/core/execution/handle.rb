# frozen_string_literal: true

require "concurrent/atomic/atomic_boolean"

module Julewire
  module Core
    module Execution
      class Handle
        def initialize(scope:, on_finish:, on_finish_failure:)
          @scope = scope
          @on_finish = on_finish
          @on_finish_failure = on_finish_failure
          @finished = Concurrent::AtomicBoolean.new
        end

        def snapshot = View.new(@scope)

        def run
          active_exception = nil
          ContextStore.current.with_scope(@scope) do
            yield self
          end
        rescue Exception => e # rubocop:disable Lint/RescueException
          active_exception = e
          raise
        ensure
          finish(reason: :error, error: active_exception) if active_exception
        end

        def with_context(&)
          ContextStore.current.with_scope(@scope, &)
        end

        def finish(reason: :closed, fields: nil, attributes: nil, error: nil, severity: nil)
          # Finishing is one-shot: retrying after partial summary mutation can
          # duplicate completion data, so failures are reported and stop here.
          return false unless mark_finished

          add_completion_attributes(reason)
          @scope.add_summary(fields)
          @scope.add_summary_attributes(attributes)
          @scope.finish_owned(error: error, severity: severity)
          call_finish
          true
        rescue StandardError => e
          report_finish_failure(e, phase: :summary_finish)
          false
        end

        private

        def mark_finished
          @finished.make_true
        end

        def add_completion_attributes(reason)
          @scope.add_summary_attributes({ "julewire.completion": reason.to_s })
        end

        def call_finish
          @on_finish&.call(@scope)
        rescue StandardError => e
          report_finish_failure(e, phase: :summary_emit)
        end

        def report_finish_failure(error, phase:)
          @on_finish_failure.call(error, phase: phase)
        rescue StandardError
          nil
        end
      end
    end
  end
end
