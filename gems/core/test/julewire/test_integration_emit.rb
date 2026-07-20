# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestIntegrationEmit < Minitest::Test
    cover Julewire::Core::Integration::Facade
    cover "Julewire::Core::FacadeMethods#attributes"
    cover "Julewire::Core::Runtime#attributes"
    cover "Julewire::Core::Runtime#emit_integration"
    def test_emit_accepts_owned_integration_records
      payload = { token: "secret" }
      seen_payload = nil
      records = configure_record_capture(
        processors: [
          lambda do |draft|
            seen_payload = draft[:payload]
            seen_payload[:processed] = true
            draft
          end
        ]
      )

      Julewire::Core::Integration::Facade.emit(
        event: "integration.event",
        source: "integration",
        payload: payload
      )

      record = records.fetch(0)

      refute_same payload, seen_payload
      refute_includes payload, :processed
      assert_equal "integration.event", record.fetch(:event)
      assert_equal "secret", record.dig(:payload, :token)
      assert_true record.dig(:payload, :processed)
    end

    def test_processors_can_mutate_owned_scope_execution_in_place
      records = configure_record_capture(
        processors: [->(draft) { draft.fetch(:execution)[:processor] = "added" }]
      )

      Julewire.with_execution(type: :request, id: "request-1") do
        Julewire::Core::Integration::Facade.emit(event: "integration.event")
      end

      record = records.find { it.fetch(:event) == "integration.event" }

      assert_equal "added", record.dig(:execution, :processor)
    end

    def test_emit_merges_owned_sections_with_scope
      context = { integration: { token: "secret" } }
      seen_context = nil
      records = configure_record_capture(
        processors: [
          lambda do |draft|
            seen_context = draft.dig(:context, :integration)
            seen_context[:processed] = true
            draft
          end
        ]
      )

      Julewire.context.add(request_id: "req-1")
      Julewire::Core::Integration::Facade.emit(
        event: "integration.event",
        source: "integration",
        context: context
      )

      record = records.fetch(0)

      refute_same context.fetch(:integration), seen_context
      refute_includes context.fetch(:integration), :processed
      assert_equal "req-1", record.dig(:context, :request_id)
      assert_equal "secret", record.dig(:context, :integration, :token)
      assert_true record.dig(:context, :integration, :processed)
    end

    def test_emit_cleans_owned_execution_relationship_fields
      records = configure_record_capture

      Julewire::Core::Integration::Facade.emit(
        event: "integration.event",
        source: "integration",
        execution: {
          type: :job,
          id: "job-1",
          depth: 10,
          root: { type: :request, id: "req-1" }
        }
      )

      execution = records.fetch(0).fetch(:execution)

      assert_equal :job, execution.fetch(:type)
      assert_equal "job-1", execution.fetch(:id)
      refute_includes execution, :depth
      refute_includes execution, :root
    end

    def test_emit_deep_merges_owned_attributes_with_scope
      records = configure_record_capture

      Julewire.attributes.add(http: { request: { method: "GET" } })
      Julewire::Core::Integration::Facade.emit(
        event: "integration.event",
        source: "integration",
        attributes: { http: { request: { path: "/orders" } } }
      )

      attributes = records.fetch(0).fetch(:attributes)

      assert_equal "GET", attributes.dig(:http, :request, :method)
      assert_equal "/orders", attributes.dig(:http, :request, :path)
    end

    def test_emit_contains_owned_top_level_string_keys_instead_of_silently_losing_them
      records = configure_record_capture

      Julewire::Core::Integration::Facade.emit("event" => "integration.event")

      error = records.fetch(0)

      assert_equal "julewire.emit_error", error.fetch(:event)
      assert_equal "TypeError", error.dig(:payload, :error, :class)
      assert_equal :emit, Julewire.health.dig(:pipeline, :last_failure, :phase)
    end

    def test_emit_rejects_owned_nested_string_keys_before_application_processors
      seen_events = []
      records = configure_record_capture(processors: [lambda { |draft|
        seen_events << draft.fetch(:event)
        nil
      }])

      Julewire::Core::Integration::Facade.emit(event: "integration.event", payload: { "token" => "secret" })

      error = records.fetch(0)

      assert_equal ["julewire.emit_error"], seen_events
      assert_equal "julewire.emit_error", error.fetch(:event)
      assert_equal "TypeError", error.dig(:payload, :error, :class)
      assert_equal :emit, Julewire.health.dig(:pipeline, :last_failure, :phase)
    end

    def test_emit_rejects_unknown_owned_top_level_fields_instead_of_losing_them
      failures = Queue.new
      records = []
      Julewire.configure do |config|
        config.on_failure = ->(error, metadata) { failures << [error, metadata] }
        configure_destination(
          config,
          formatter: Core::TestHelpers::RecordCaptureFormatter.new(records),
          output: Julewire::Testing::NullOutput.new
        )
      end

      Julewire::Core::Integration::Facade.emit(event: "integration.event", custom: "lost")

      error = records.fetch(0)
      failure, metadata = safe_queue_pop(failures)

      assert_equal "julewire.emit_error", error.fetch(:event)
      assert_equal "owned record input has unknown top-level keys: custom", failure.message
      assert_equal :emit, metadata.fetch(:phase)
    end

    def test_emit_records_no_output_and_level_drops
      Julewire::Core::Integration::Facade.emit(message: "no sink")

      assert_equal 1, Julewire.health.dig(:pipeline, :counts, :no_output_dropped)

      output = StringIO.new
      configure_default_output(output)
      Julewire.configure { it.level = :fatal }

      Julewire::Core::Integration::Facade.emit(severity: :debug, message: "dropped")

      assert_empty output.string
      assert_equal 1, Julewire.health.dig(:pipeline, :counts, :level_dropped)
    end

    def test_runtime_emit_integration_enforces_level_by_default
      records = configure_record_capture(level: :warn)

      Core::RuntimeLocator.current.emit_integration({ event: "adapter.debug", severity: :debug })

      assert_empty records
      assert_equal 1, Julewire.health.dig(:pipeline, :counts, :level_dropped)
    end

    def test_runtime_emit_integration_can_bypass_level_threshold
      records = configure_record_capture(level: :fatal)

      Core::RuntimeLocator.current.emit_integration({ event: "adapter.debug", severity: :debug }, enforce_level: false)

      assert_equal 1, records.length
      assert_equal "adapter.debug", records.fetch(0).fetch(:event)
      assert_equal :debug, records.fetch(0).fetch(:severity)
      assert_equal 0, Julewire.health.dig(:pipeline, :counts, :level_dropped)
    end

    def test_runtime_emit_integration_failures_record_integration_action
      runtime = Core::RuntimeLocator.current
      failures = configure_runtime_failure_capture(runtime)
      pipeline = runtime.__send__(:runtime_state).pipeline

      with_overridden_singleton_method(pipeline, :emit_integration, proc { |_record, **| raise "adapter failed" }) do
        assert_nil runtime.emit_integration({ event: "adapter.failed" })
      end

      error, metadata = failures.pop(timeout: 1)

      assert_equal "adapter failed", error.message
      assert_equal :runtime, metadata.fetch(:phase)
      assert_equal :emit_integration, metadata.fetch(:action)
    end
  end
end
