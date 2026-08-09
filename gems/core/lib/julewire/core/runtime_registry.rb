# frozen_string_literal: true

require "concurrent/atomic/atomic_reference"

module Julewire
  module Core
    module RuntimeRegistry
      DEFAULT_NAME = :default
      EMPTY_RUNTIMES = {}.freeze
      private_constant :DEFAULT_NAME, :EMPTY_RUNTIMES

      @runtimes = Concurrent::AtomicReference.new(EMPTY_RUNTIMES)

      class << self
        def fetch(name, current: RuntimeLocator.current)
          name = Core.normalize_name(name, name: "runtime name")
          return current if name == DEFAULT_NAME

          unless current.is_a?(Runtime)
            raise Error, "named Julewire runtimes are not available from the current runtime"
          end

          @runtimes.update do |runtimes|
            if runtimes.key?(name)
              runtimes
            else
              runtimes.merge(name => Runtime.new)
            end
          end.fetch(name)
        end

        def reset(primary:)
          runtimes = @runtimes.get_and_set(EMPTY_RUNTIMES).values

          primary.reset!
          runtimes.each(&:reset!)
          nil
        end

        def reset_after_fork(primary:)
          runtimes = [primary] + @runtimes.get.values

          ContextStore.reset_current!
          Scheduling::SharedScheduler.after_fork!
          Diagnostics::ProcessIntegrationHealth.reset!
          Diagnostics::InvalidSeverityReporter.reset!
          runtimes.each(&:reset_after_fork_runtime!)
          Integration::ForkHooks.run
        end

        def prepare_before_fork(primary:, timeout:)
          Validation.validate_timeout!(timeout, name: :timeout)
          runtimes = [primary] + @runtimes.get.values
          deadline = Scheduling::Deadline.for(timeout)

          runtimes.each do |runtime|
            runtime.before_fork_runtime!(timeout: Scheduling::Deadline.remaining(deadline))
          end
          Integration::BeforeForkHooks.run
        rescue StandardError
          runtimes&.reverse_each(&:cancel_before_fork_runtime!)
          raise
        end
      end
    end
  end
end
