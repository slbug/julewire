# frozen_string_literal: true

module Julewire
  module ActiveJobHelpers
    def fake_job
      ActiveJobFixtures::FakeJob.new
    end

    def active_job_attributes(record)
      record.dig(:attributes, :active_job) || {}
    end

    def assert_other_event_record(record)
      assert_equal "other.event", record.fetch(:event)
    end

    def assert_source_location_attributes(record)
      assert_equal "app/jobs/import_job.rb", record.dig(:neutral, :"code.file.path")
      assert_equal 42, record.dig(:neutral, :"code.line.number")
      assert_equal "ImportJob#perform", record.dig(:neutral, :"code.function.name")
    end

    def assert_active_job_record_contract(record)
      assert_julewire_record_source_contract(
        records: [record],
        event: "other.event",
        source: "active_job",
        logger: "ActiveJob.event",
        kind: "point",
        event_path: %i[event],
        source_path: %i[source],
        logger_path: %i[logger],
        kind_path: %i[kind]
      )
    end

    def real_active_job_configuration
      Julewire::ActiveJob::Configuration.new.tap do |configuration|
        configuration.execution = false
        configuration.structured_events = false
        configuration.silence_log_subscriber = false
      end
    end

    def with_active_job_config(attribute, value)
      previous = Julewire::ActiveJob.config.public_send(attribute)
      Julewire::ActiveJob.config.public_send("#{attribute}=", value)
      yield
    ensure
      Julewire::ActiveJob.config.public_send("#{attribute}=", previous) if defined?(previous)
    end

    def serialize_fake_job_with_context
      Julewire.context.with(request_id: "request-1") do
        ActiveJobFixtures::FakeSerializedJob.new.serialize
      end
    end

    def with_real_active_job_class(constant_name, base: ::ActiveJob::Base)
      Object.send(:remove_const, constant_name) if Object.const_defined?(constant_name)
      job_class = Class.new(base) do
        def perform; end
      end
      Object.const_set(constant_name, job_class)
      yield job_class
    ensure
      Object.send(:remove_const, constant_name) if Object.const_defined?(constant_name)
    end

    def serialize_real_job(job_class)
      Julewire.with_execution(type: :request, id: "request-1") do
        Julewire.context.add(request_id: "request-1")
        job_class.new.serialize
      end
    end

    def reset_active_job_event_reporter_subscriber!
      Julewire::ActiveJob::Subscribers::Event.reset!
    end

    def active_support_event_reporter?
      defined?(::ActiveSupport) && ::ActiveSupport.respond_to?(:event_reporter)
    end

    def assert_active_job_structured_events(events)
      assert_includes events, "active_job.started"
      assert_includes events, "active_job.completed"
      assert_includes events, "active_job.enqueued"
    end

    def exercise_active_job_contract(emit_point:, add_summary:, context:, carry:, summary_event:, **)
      job = fake_job
      job.instance_variable_set(:@julewire_carrier, contract_carrier(context: context, carry: carry))
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.summary_event = summary_event

      Julewire::ActiveJob::JobExecution.call(job, configuration: configuration) do
        add_summary.call
        emit_point.call
      end
    end

    def contract_carrier(context:, carry:)
      Julewire.with_execution(type: :producer, id: "producer-1", emit_summary: false) do
        Julewire.context.add(context)
        Julewire.carry.add(carry)
        Julewire::Core::Propagation::Carrier.inject({})
      end
    end

    def with_overridden_singleton_method(receiver, method_name, replacement, &)
      Julewire::Core::Testing.with_overridden_singleton_method(receiver, method_name, replacement, &)
    end
  end
end
