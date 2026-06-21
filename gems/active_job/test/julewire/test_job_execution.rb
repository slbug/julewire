# frozen_string_literal: true

require "support/active_job_test_support"

module Julewire
  class TestActiveJobJobExecution < Minitest::Test
    include ActiveJobTestSupport

    cover Julewire::ActiveJob::JobAttributes
    cover Julewire::ActiveJob::JobExecution

    def test_job_execution_restores_carrier_and_emits_summary # rubocop:disable Metrics/AbcSize
      records = capture_records
      carrier = nil

      Julewire.with_execution(type: :request, id: "request-1") do
        Julewire.context.add(request_id: "request-1")
        carrier = Julewire::Core::Propagation::Carrier.inject({})
      end

      job = fake_job
      job.instance_variable_set(:@julewire_carrier, carrier)

      Julewire::ActiveJob::JobExecution.call(job, configuration: Julewire::ActiveJob::Configuration.new) do
        Julewire.emit(event: "job.point", source: "test", payload: { ok: true })
      end

      point = records.find { it[:event] == "job.point" }
      summary = records.find { it[:event] == "job.completed" }

      refute point.fetch(:neutral).key?(:"job.status")
      assert_equal "request-1", point.dig(:context, :request_id)
      assert_equal "job-1", point.dig(:context, :job_id)
      assert_equal :summary, summary[:kind]
      assert_equal "ok", active_job_attributes(summary).fetch(:status)
      assert_equal "Julewire::ActiveJobFixtures::FakeJob", active_job_attributes(summary).fetch(:job_class)
      assert_equal "job-1", active_job_attributes(summary).fetch(:job_id)
      assert_equal "active_job", summary.dig(:neutral, :"job.system")
      assert_equal "Julewire::ActiveJobFixtures::FakeJob", summary.dig(:neutral, :"job.name")
      assert_equal "job-1", summary.dig(:neutral, :"job.id")
      assert_equal "ok", summary.dig(:neutral, :"job.status")
    end

    def test_job_execution_skips_carrier_restore_when_propagation_is_disabled
      records = capture_records
      carrier = carrier_with_request_context

      configuration = Julewire::ActiveJob::Configuration.new
      configuration.propagation = false
      job = fake_job
      job.instance_variable_set(:@julewire_carrier, carrier)

      emit_job_point(job, configuration)

      assert_job_point_without_restored_request(records)
    end

    def test_job_execution_skips_oversized_inbound_carrier_restore
      records = capture_records
      carrier = carrier_with_request_context

      configuration = Julewire::ActiveJob::Configuration.new
      configuration.carrier_max_bytes = carrier.fetch(configuration.carrier_key).bytesize - 1
      job = fake_job
      job.instance_variable_set(:@julewire_carrier, carrier)

      emit_job_point(job, configuration)

      assert_job_point_without_restored_request(records)
      failure = Julewire.health.dig(:process_integrations, :active_job, :last_failure)

      assert_equal :carrier_restore, failure.fetch(:action)
      assert_equal :job_execution, failure.fetch(:component)
      assert_equal :oversized, failure.fetch(:status)
    end

    def test_job_execution_records_error_summary_and_reraises
      records = capture_records

      error = assert_raises(RuntimeError) do
        Julewire::ActiveJob::JobExecution.call(RaisingJob.new, configuration: Julewire::ActiveJob::Configuration.new) do
          raise "boom"
        end
      end

      summary = records.find { it[:kind] == :summary }

      assert_equal "boom", error.message
      assert_equal "error", active_job_attributes(summary).fetch(:status)
      assert_equal "RuntimeError", active_job_attributes(summary).fetch(:exception_class)
      assert_equal "already serialized", active_job_attributes(summary).fetch(:enqueued_at)
      assert_equal "error", summary.dig(:neutral, :"job.status")
      assert_equal "RaisingJob", summary.dig(:neutral, :"job.name")
      refute active_job_attributes(summary).key?(:provider_job_id)
    end

    def test_job_execution_contains_carrier_and_summary_failures
      broken_job = Object.new
      def broken_job.instance_variable_get(_name) = raise("carrier failed")

      perform_fake_job(broken_job) do
        Julewire.emit(event: "broken.job")
      end

      with_overridden_singleton_method(Julewire, :summary, proc { FakeSummary.new }) do
        perform_fake_job(fake_job) { :ok }
      end
    end

    def test_job_execution_skips_empty_context_fields
      records = capture_records
      anonymous_job = Class.new.new

      perform_fake_job(anonymous_job) do
        Julewire.emit(event: "anonymous.job")
      end

      point = records.find { it[:event] == "anonymous.job" }

      assert_empty point.fetch(:context)
    end

    def test_job_execution_satisfies_julewire_execution_boundary_contract
      destination = Julewire::Core::Testing::CaptureDestination.new

      assert_julewire_execution_boundary_contract(
        configure: ->(config) { config.destinations.add(destination) },
        exercise: method(:exercise_active_job_contract),
        records: -> { destination.records },
        event_path: %i[event],
        context_path: %i[context],
        carry_path: %i[carry],
        summary_payload_path: %i[payload],
        destination_name: :capture
      )
    end

    def test_real_active_job_inline_execution_uses_julewire_boundary
      reset_active_job_event_reporter_subscriber!
      ::ActiveJob::Base.queue_adapter = :inline
      Julewire::ActiveJob.install!(base: ::ActiveJob::Base)
      subscriber = Julewire::ActiveJob::Subscribers::Event.subscriber

      refute_nil subscriber, "structured event subscriber should install on Rails 8.1"
      records = capture_records
      Object.send(:remove_const, :InlineSmokeJob) if Object.const_defined?(:InlineSmokeJob)
      Object.const_set(:InlineSmokeJob, Class.new(::ActiveJob::Base) do
        def perform
          Julewire.emit(event: "inline.smoke", source: "test")
        end
      end)

      ::InlineSmokeJob.perform_later

      events = records.map { it[:event] }

      assert_includes events, "inline.smoke"
      assert_includes events, "job.completed"
      assert_active_job_structured_events(events)
    ensure
      Object.send(:remove_const, :InlineSmokeJob) if Object.const_defined?(:InlineSmokeJob)
    end

    private

    def carrier_with_request_context
      Julewire.context.with(request_id: "request-1") do
        Julewire::Core::Propagation::Carrier.inject({})
      end
    end

    def assert_job_point_without_restored_request(records)
      point = records.find { it[:event] == "job.point" }

      refute point.fetch(:context).key?(:request_id)
      assert_equal "job-1", point.dig(:context, :job_id)
    end

    def emit_job_point(job, configuration)
      Julewire::ActiveJob::JobExecution.call(job, configuration: configuration) do
        Julewire.emit(event: "job.point", source: "test")
      end
    end

    def perform_fake_job(job, &)
      Julewire::ActiveJob::JobExecution.call(job, configuration: Julewire::ActiveJob::Configuration.new, &)
    end
  end
end
