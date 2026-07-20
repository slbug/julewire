# frozen_string_literal: true

module Julewire
  module ActiveJob
    module Installer
      EXECUTION_INSTALL = Core::Integration::IvarState.new(:@julewire_active_job_execution)

      class << self
        def install!(base: nil, event_reporter: nil, configuration: Configuration.new)
          return unless configuration.enabled?

          ActiveJob.config = configuration
          base ||= active_job_base
          raise Error, "ActiveJob::Base is not available" unless base

          install_serialization(base, configuration)
          install_execution_callback(base, configuration)
          Subscribers::Event.install!(configuration, event_reporter: event_reporter)
          LogSubscriberSilencer.silence! if configuration.silence_log_subscriber?
          base
        end

        private

        def active_job_base
          require "active_job/base"
          ::ActiveJob::Base
        end

        def install_serialization(base, configuration)
          install_serialization_configuration(base, configuration)

          base.prepend(JobSerialization)
        end

        def install_serialization_configuration(base, configuration)
          if base.singleton_methods(false).include?(JobSerialization::CONFIGURATION_METHOD)
            base.singleton_class.remove_method(JobSerialization::CONFIGURATION_METHOD)
          end
          base.define_singleton_method(JobSerialization::CONFIGURATION_METHOD) { configuration }
        end

        def install_execution_callback(base, configuration)
          return unless configuration.execution?

          installed = EXECUTION_INSTALL.fetch(base)
          if installed
            installed.configuration = configuration
            return
          end

          callback = ExecutionCallback.new(configuration)
          # Rails callbacks are easier to update in place than to remove safely.
          base.around_perform do |job, block|
            callback.call(job, &block)
          end
          EXECUTION_INSTALL.store(base, callback)
        end
      end

      class ExecutionCallback
        def initialize(configuration)
          @configuration = configuration
        end

        attr_writer :configuration

        def call(job, &)
          JobExecution.call(job, configuration: @configuration, &)
        end
      end
      private_constant :ExecutionCallback
    end
  end
end
