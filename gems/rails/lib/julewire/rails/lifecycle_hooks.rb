# frozen_string_literal: true

module Julewire
  module Rails
    module LifecycleHooks
      @at_exit_installed = false
      @fork_tracker_installed = false
      @mutex = Mutex.new

      class << self
        def install!(configuration, registrar: Kernel, fork_tracker: active_support_fork_tracker)
          return unless configuration.lifecycle_hooks?

          @mutex.synchronize do
            install_at_exit!(registrar, configuration)
            register_after_fork!
            install_fork_tracker!(fork_tracker)
          end
        end

        def drain!(timeout:)
          Julewire.flush(timeout: timeout)
        ensure
          Julewire.close(timeout: timeout)
        end

        def after_fork!
          RequestSummaryTimeoutScheduler.after_fork!
          RequestErrorOwnership.clear
        end

        # Private testing seam for isolating process lifecycle hooks.
        def reset_for_test!
          @mutex.synchronize do
            @at_exit_installed = false
            @fork_tracker_installed = false
          end
        end

        private

        private :reset_for_test!

        def install_at_exit!(registrar, configuration)
          return if @at_exit_installed

          registrar.at_exit { drain!(timeout: configuration.shutdown_timeout) }
          @at_exit_installed = true
        end

        def register_after_fork!
          Core::Integration::Lifecycle.register_after_fork(:rails, component: :lifecycle_hooks) { after_fork! }
        end

        def install_fork_tracker!(fork_tracker)
          return if @fork_tracker_installed
          return unless fork_tracker.respond_to?(:after_fork)

          fork_tracker.after_fork { Julewire.after_fork! }
          @fork_tracker_installed = true
        rescue StandardError => e
          IntegrationHealth.record_failure(
            e,
            action: :install_after_fork,
            component: :lifecycle_hooks
          )
          nil
        end

        def active_support_fork_tracker
          ::ActiveSupport::ForkTracker if defined?(::ActiveSupport::ForkTracker)
        end
      end
    end
  end
end
