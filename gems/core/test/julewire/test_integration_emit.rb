# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestIntegrationEmit < Minitest::Test
    class RuntimeWithoutIntegrationEmit
      attr_reader :calls

      def initialize
        @calls = []
      end

      def emit(record)
        @calls << [:emit, record]
      end

      def emit_without_level(record)
        @calls << [:emit_without_level, record]
      end
    end

    def test_emit_accepts_owned_integration_records
      payload = { token: "secret" }
      seen_payload = nil
      records = configure_record_capture(
        processors: [
          lambda do |draft|
            seen_payload = draft[:payload]
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

      assert_same payload, seen_payload
      assert_equal "integration.event", record.fetch(:event)
      assert_equal "secret", record.dig(:payload, :token)
    end

    def test_emit_merges_owned_sections_with_scope
      context = { integration: { token: "secret" } }
      seen_context = nil
      records = configure_record_capture(
        processors: [
          lambda do |draft|
            seen_context = draft.dig(:context, :integration)
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

      assert_same context.fetch(:integration), seen_context
      assert_equal "req-1", record.dig(:context, :request_id)
      assert_equal "secret", record.dig(:context, :integration, :token)
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

    def test_emit_falls_back_for_bridge_runtimes_without_integration_emit
      runtime = RuntimeWithoutIntegrationEmit.new
      Julewire::Core::RuntimeLocator.current = runtime

      Julewire::Core::Integration::Facade.emit(message: "level")
      Julewire::Core::Integration::Facade.emit({ message: "without-level" }, enforce_level: false)

      assert_equal(
        [[:emit, { message: "level" }], [:emit_without_level, { message: "without-level" }]],
        runtime.calls
      )
    ensure
      Julewire::Core::RuntimeLocator.current = Julewire::Core::Runtime.new
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
  end
end
