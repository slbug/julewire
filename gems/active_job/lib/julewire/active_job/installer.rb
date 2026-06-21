# frozen_string_literal: true

module Julewire
  module ActiveJob
    module Installer
      EXECUTION_INSTALL = Core::Integration::IvarState.new(:@julewire_active_job_execution)

      class << self
        def install!(base: nil, event_reporter: nil, configuration: Configuration.new)
          return unless configuration.enabled?

          Julewire::ActiveJob.config = configuration
          base ||= active_job_base
          raise Error, "ActiveJob::Base is not available" unless base

          install_serialization(base, configuration)
          install_execution_callback(base, configuration)
          if configuration.structured_events?
            Subscribers::Event.install!(configuration, event_reporter: event_reporter)
          else
            Subscribers::Event.reset!
          end
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
          return if base < JobSerialization

          base.prepend(JobSerialization)
        end

        def install_serialization_configuration(base, configuration)
          if base.respond_to?(:class_attribute)
            unless base.respond_to?(JobSerialization::CONFIGURATION_METHOD)
              base.class_attribute(
                JobSerialization::CONFIGURATION_METHOD,
                instance_accessor: false,
                instance_predicate: false
              )
            end
            base.public_send("#{JobSerialization::CONFIGURATION_METHOD}=", configuration)
          else
            base.instance_variable_set(JobSerialization::CONFIGURATION_IVAR, configuration)
          end
        end

        def install_execution_callback(base, configuration)
          return unless configuration.execution?

          installed = EXECUTION_INSTALL.fetch(base)
          if installed
            installed.configuration = configuration
            return installed
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
          Julewire::ActiveJob::JobExecution.call(job, configuration: @configuration, &)
        end
      end
      private_constant :ExecutionCallback
    end
  end
end
