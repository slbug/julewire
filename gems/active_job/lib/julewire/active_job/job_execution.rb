# frozen_string_literal: true

require "time"

module Julewire
  module ActiveJob
    module JobExecution
      class << self
        def call(job, configuration: Configuration.new, &)
          carrier = carrier_for(job)
          return perform_job(job, configuration, &) unless configuration.propagation?

          result = Julewire::Core::Propagation::Carrier.extract_result(
            carrier,
            key: configuration.carrier_key,
            max_bytes: configuration.carrier_max_bytes
          )
          record_carrier_restore_failure(result)

          Julewire::Core::Propagation.restore(result.envelope, owned: true) do
            perform_job(job, configuration, &)
          end
        end

        private

        def record_carrier_restore_failure(result)
          return unless result.failure?

          IntegrationHealth.record_failure(
            result.error,
            action: :carrier_restore,
            component: :job_execution,
            status: result.status,
            reason: result.reason
          )
        end

        def perform_job(job, configuration, &)
          fields = job_fields(job)
          Core::Integration::Facade.with_execution(**execution_options(job, configuration, fields)) do
            install_context(fields)
            perform_with_summary(&)
          end
        end

        def carrier_for(job)
          job.instance_variable_get(CARRIER_IVAR) || {}
        rescue StandardError
          {}
        end

        def execution_options(job, configuration, fields)
          options = {
            type: :job,
            fields: { job_class: fields[:job_class] || job.class.name },
            attributes: attributes_for(fields),
            neutral: neutral_for(fields),
            inherit_attributes: false,
            summary_event: configuration.summary_event,
            summary_severity: configuration.summary_severity,
            summary_source: configuration.source
          }
          job_id = fields[:job_id]
          options[:id] = job_id if job_id
          options
        end

        def install_context(fields)
          job_id = fields[:job_id]
          Core::Integration::Facade.add_context(job_id: job_id) if job_id
        end

        def perform_with_summary
          result = yield
          add_summary(status: "ok")
          result
        rescue StandardError => e
          add_summary(status: "error", exception_class: e.class.name)
          raise
        end

        def add_summary(fields)
          add_summary_neutral(fields)
          Core::Integration::Facade.add_summary_attributes(completion_attributes(fields))
        rescue StandardError
          nil
        end

        def job_fields(job)
          values = Core::Integration::Values::Shape
          fields = { job_class: job.class.name }
          values.append_field(fields, :job_id, job_id(job))
          values.append_field(fields, :provider_job_id, safe_call(job, :provider_job_id))
          values.append_field(fields, :queue, safe_call(job, :queue_name))
          values.append_field(fields, :priority, safe_call(job, :priority))
          values.append_field(fields, :executions, safe_call(job, :executions))
          values.append_field(
            fields,
            :enqueued_at,
            values.timestamp(safe_call(job, :enqueued_at))
          )
          values.append_field(
            fields,
            :scheduled_at,
            values.timestamp(safe_call(job, :scheduled_at))
          )
          fields
        end

        def job_id(job)
          safe_call(job, :job_id)
        end

        def attributes_for(fields)
          { active_job: fields }
        end

        def neutral_for(fields)
          JobAttributes.call(fields)
        end

        def add_summary_neutral(fields)
          Core::Integration::Facade.add_summary_neutral(JobAttributes.call(fields))
        end

        def completion_attributes(fields)
          { active_job: fields }
        end

        def safe_call(object, method_name)
          Core::Integration::Values::Read.value(object, method_name)
        end
      end
    end
  end
end
