# frozen_string_literal: true

module Julewire
  module Core
    module RuntimeRegistry
      DEFAULT_NAME = :default
      private_constant :DEFAULT_NAME

      @mutex = Mutex.new
      @runtimes = {}

      class << self
        def fetch(name, current: RuntimeLocator.current)
          name = Core.normalize_name(name, name: "runtime name")
          return current if name == DEFAULT_NAME

          unless current.is_a?(Runtime)
            raise Error, "named Julewire runtimes are not available from the current runtime"
          end

          @mutex.synchronize { @runtimes[name] ||= Runtime.new }
        end

        def clear!
          @mutex.synchronize { @runtimes.clear }
          nil
        end

        def reset_after_fork(primary:)
          # Post-fork execution is single-threaded; do not touch inherited locks
          # before rebuilding them.
          runtimes = ([primary] + @runtimes.values).uniq
          @mutex = Mutex.new

          LocalStorage.after_fork!
          ContextStore.reset_current!
          Scheduling::SharedScheduler.after_fork!
          Diagnostics::ProcessIntegrationHealth.after_fork!
          Integration::ForkHooks.after_fork!
          Diagnostics::InvalidSeverityReporter.reset_after_fork!
          runtimes.each(&:reset_after_fork_runtime!)
          Integration::ForkHooks.run
          nil
        end
      end
    end
  end
end
