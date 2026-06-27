# frozen_string_literal: true

module Julewire
  module ActiveJobHelpers
    include Julewire::TestSupport::MethodOverride

    def fake_job
      ActiveJobFixtures::FakeJob.new
    end

    def active_job_attributes(record)
      record.dig(:attributes, :active_job) || {}
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
  end
end
