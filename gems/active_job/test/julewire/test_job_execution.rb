# frozen_string_literal: true

require "support/active_job_test_support"

module Julewire
  class TestActiveJobJobExecution < Minitest::Test
    cover Julewire::ActiveJob::JobExecution
    include ActiveJobTestSupport

    def test_job_execution_restores_carrier_and_emits_summary
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

      assert_false point.fetch(:neutral).key?(:"job.status")
      assert_equal "request-1", point.dig(:context, :request_id)
      assert_equal "job-1", point.dig(:context, :job_id)
      assert_equal :summary, summary[:kind]
      assert_empty Julewire.health.fetch(:process_integrations)
      assert_equal "ok", active_job_attributes(summary).fetch(:status)
      assert_equal "Julewire::ActiveJobFixtures::FakeJob", active_job_attributes(summary).fetch(:job_class)
      assert_equal "job-1", active_job_attributes(summary).fetch(:job_id)
      assert_equal "provider-1", active_job_attributes(summary).fetch(:provider_job_id)
      assert_equal "default", active_job_attributes(summary).fetch(:queue)
      assert_equal 10, active_job_attributes(summary).fetch(:priority)
      assert_equal 1, active_job_attributes(summary).fetch(:executions)
      assert_equal "2026-01-01T00:00:00.000000000Z", active_job_attributes(summary).fetch(:enqueued_at)
      assert_equal "active_job", summary.dig(:neutral, :"job.system")
      assert_equal "Julewire::ActiveJobFixtures::FakeJob", summary.dig(:neutral, :"job.name")
      assert_equal "job-1", summary.dig(:neutral, :"job.id")
      assert_equal "provider-1", summary.dig(:neutral, :"job.provider_id")
      assert_equal "default", summary.dig(:neutral, :"job.queue.name")
      assert_equal 10, summary.dig(:neutral, :"job.priority")
      assert_equal 1, summary.dig(:neutral, :"job.execution_count")
      assert_equal "2026-01-01T00:00:00.000000000Z", summary.dig(:neutral, :"job.enqueued_at")
      assert_equal "ok", summary.dig(:neutral, :"job.status")
      assert_equal "job-1", summary.dig(:execution, :id)
      assert_equal "job", summary.dig(:execution, :type)
      assert_equal "Julewire::ActiveJobFixtures::FakeJob", summary.dig(:execution, :job_class)
    end

    def test_job_execution_records_scheduled_at_when_present
      records = capture_records
      job = fake_job
      job.instance_variable_set(:@scheduled_at, Time.utc(2026, 1, 1, 0, 5))

      emit_job_point(job, Julewire::ActiveJob::Configuration.new)

      summary = records.find { it[:kind] == :summary }

      assert_equal "2026-01-01T00:05:00.000000000Z", active_job_attributes(summary).fetch(:scheduled_at)
      assert_equal "2026-01-01T00:05:00.000000000Z", summary.dig(:neutral, :"job.scheduled_at")
    end

    def test_job_execution_uses_configured_summary_source
      records = capture_records
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.source = "jobs"

      emit_job_point(fake_job, configuration)

      summary = records.find { it[:kind] == :summary }

      assert_equal "jobs", summary.fetch(:source)
    end

    def test_job_execution_uses_configured_summary_severity
      records = capture_records
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.summary_severity = :debug

      emit_job_point(fake_job, configuration)

      summary = records.find { it[:kind] == :summary }

      assert_equal :debug, summary.fetch(:severity)
    end

    def test_job_execution_treats_nil_carrier_as_empty
      records = capture_records
      job = fake_job
      job.instance_variable_set(:@julewire_carrier, nil)

      emit_job_point(job, Julewire::ActiveJob::Configuration.new)

      point = records.find { it[:event] == "job.point" }

      assert_false point.fetch(:context).key?(:request_id)
      assert_empty Julewire.health.fetch(:process_integrations)
    end

    def test_job_execution_restores_configured_carrier_key
      records = capture_records
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.carrier_key = :custom_julewire
      carrier = Julewire.context.with(request_id: "request-custom") do
        Julewire::Core::Propagation::Carrier.inject({}, key: :custom_julewire)
      end
      job = fake_job
      job.instance_variable_set(:@julewire_carrier, carrier)

      emit_job_point(job, configuration)

      point = records.find { it[:event] == "job.point" }

      assert_equal "request-custom", point.dig(:context, :request_id)
    end

    def test_job_execution_does_not_inherit_parent_attributes
      records = capture_records

      Julewire.with_execution(type: :request, id: "request-1") do
        Julewire.attributes.add(parent: "request")
        emit_job_point(fake_job, Julewire::ActiveJob::Configuration.new)
      end

      point = records.find { it[:event] == "job.point" }

      assert_false point.fetch(:attributes).key?(:parent)
      assert_equal "Julewire::ActiveJobFixtures::FakeJob", point.dig(:attributes, :active_job, :job_class)
    end

    def test_job_execution_skips_carrier_restore_when_propagation_is_disabled
      records = capture_records
      carrier = carrier_with_request_context

      configuration = Julewire::ActiveJob::Configuration.new
      configuration.propagation = false
      job = fake_job
      job.instance_variable_set(:@julewire_carrier, carrier)

      result = Julewire::ActiveJob::JobExecution.call(job, configuration: configuration) do
        Julewire.emit(event: "job.point", source: "test")
        "performed"
      end

      assert_equal "performed", result
      assert_equal(1, records.count { it[:event] == "job.point" })
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

    def test_job_execution_records_malformed_carrier_restore_failure
      records = capture_records
      job = fake_job
      job.instance_variable_set(:@julewire_carrier, { "julewire" => "{" })

      emit_job_point(job, Julewire::ActiveJob::Configuration.new)

      assert_job_point_without_restored_request(records)
      failure = Julewire.health.dig(:process_integrations, :active_job, :last_failure)

      assert_equal :carrier_restore, failure.fetch(:action)
      assert_equal :job_execution, failure.fetch(:component)
      assert_equal :malformed, failure.fetch(:status)
      assert_equal "carrier payload is not valid JSON", failure.fetch(:reason)
      assert_equal "Julewire::Core::Propagation::Carrier::ExtractionError", failure.fetch(:class)
    end

    def test_job_execution_restores_truncated_carrier_context
      records = capture_records
      job = fake_job
      job.instance_variable_set(:@julewire_carrier, carrier_with_truncated_context)

      emit_job_point(job, Julewire::ActiveJob::Configuration.new)

      context = records.find { it[:event] == "job.point" }.fetch(:context)

      assert_truncated_context(context)
      assert_equal "job-1", context.fetch(:job_id)
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
      assert_false active_job_attributes(summary).key?(:provider_job_id)
    end

    def test_job_execution_contains_carrier_and_summary_failures
      broken_job = Object.new
      def broken_job.instance_variable_get(_name) = raise("carrier failed")

      perform_fake_job(broken_job) do
        Julewire.emit(event: "broken.job")
      end

      with_overridden_singleton_method(
        Julewire::Core::Integration::Facade,
        :add_summary_attributes,
        proc { |_fields| raise "summary failed" }
      ) do
        assert_equal :ok, perform_fake_job(fake_job) { :ok }
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

    def test_job_execution_restores_context_and_emits_point_and_summary
      destination = Julewire::Testing::CaptureDestination.new
      traceparent = "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01"
      job = fake_job
      carrier = Julewire.with_execution(type: :producer, id: "producer-1", emit_summary: false) do
        Julewire.context.add(request_id: "request-1")
        Julewire.carry.add(http: { request_headers: { traceparent: traceparent } })
        Julewire::Core::Propagation::Carrier.inject({})
      end
      job.instance_variable_set(:@julewire_carrier, carrier)
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.summary_event = "contract.completed"

      Julewire.configure { it.destinations.add(destination) }
      Julewire::ActiveJob::JobExecution.call(job, configuration: configuration) do
        Julewire.summary.add(total: 2)
        Julewire.emit(event: "contract.point", source: "contract", message: "point", payload: { value: 1 })
      end
      Julewire.flush

      point = destination.records.find { it[:event] == "contract.point" }
      summary = destination.records.find { it[:event] == "contract.completed" }

      assert_equal "request-1", point.dig(:context, :request_id)
      assert_equal traceparent, point.dig(:carry, :http, :request_headers, :traceparent)
      assert_equal 2, summary.dig(:payload, :total)
      assert_equal :ok, Julewire.health.fetch(:status)
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

    def carrier_with_truncated_context
      {
        "julewire" => Julewire::Core::Propagation::Carrier.encode(
          envelope: { context: { blob: "x" * 20_000 } }
        )
      }
    end

    def assert_truncated_context(context)
      assert_match(/\Ax+\.\.\.\[Truncated\]\z/, context.fetch(:blob))
      metadata = context.fetch(:_julewire_truncation)

      assert_true metadata.fetch(:truncated)
      assert_equal ["blob"], metadata.fetch(:truncated_fields)
      assert_equal Julewire::Core::Serialization::Serializer::DEFAULT_MAX_STRING_BYTES,
                   metadata.dig(:limits, :max_string_bytes)
    end

    def assert_job_point_without_restored_request(records)
      point = records.find { it[:event] == "job.point" }

      assert_false point.fetch(:context).key?(:request_id)
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
