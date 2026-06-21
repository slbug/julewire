# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestIntegrationFieldOverlays < Minitest::Test
    cover Julewire::Core::Fields::FieldStack

    OVERLAY_CASES = [
      {
        event: "message.processed",
        source: "message_bus",
        context: { request_id: "req-1" },
        carry: { trace: { id: "trace-1" } },
        attributes: { message_bus: { topic: "events" } },
        neutral: { messaging: { destination: "events" } },
        expected_context: [:request_id, "req-1"],
        expected_attribute: [%i[message_bus topic], "events"],
        expected_neutral: [%i[messaging destination], "events"]
      },
      {
        event: "request.point",
        source: "web",
        context: { controller: "OrdersController" },
        carry: { trace: { id: "trace-1" } },
        attributes: { web: { action: "create" } },
        neutral: { http: { request: { method: "GET" } } },
        expected_context: [:controller, "OrdersController"],
        expected_attribute: [%i[web action], "create"],
        expected_neutral: [%i[http request method], "GET"],
        execution: true
      }
    ].freeze
    ADD_CASES = [
      {
        event: "job.point",
        source: "active_job",
        context: { job_id: "job-1" },
        attributes: { active_job: { queue: "default" } },
        neutral: { job: { queue: { name: "default" } } },
        expected_context: [:job_id, "job-1"],
        expected_attribute: [%i[active_job queue], "default"],
        expected_neutral: [%i[job queue name], "default"],
        execution: true
      },
      {
        event: "request.point",
        source: "web",
        context: { request_id: "req-1" },
        attributes: { web: { controller: "OrdersController" } },
        neutral: { http: { route: "/orders" } },
        expected_context: [:request_id, "req-1"],
        expected_attribute: [%i[web controller], "OrdersController"],
        expected_neutral: [%i[http route], "/orders"]
      }
    ].freeze
    private_constant :OVERLAY_CASES
    private_constant :ADD_CASES

    def test_integration_field_helpers_install_owned_fields
      records = capture_julewire_records do
        emit_cases(OVERLAY_CASES, strategy: :overlay)
        emit_cases(ADD_CASES, strategy: :add)
      end

      (OVERLAY_CASES + ADD_CASES).each_with_index do |entry, index|
        assert_overlay_point(records.fetch(index), entry)
      end
    end

    def test_with_field_overlays_ignore_non_hash_fields
      records = capture_julewire_records do
        Julewire::Core::Integration::Facade.with_context(nil) do
          Julewire::Core::Integration::Facade.with_carry("trace-1") do
            Julewire::Core::Integration::Facade.with_attributes(Object.new) do
              Julewire::Core::Integration::Facade.with_neutral(false) do
                Julewire.emit(event: "ignored.fields", source: "test")
              end
            end
          end
        end
      end

      point = records.fetch(0)

      assert_empty point.fetch(:context)
      assert_empty point.fetch(:carry)
      assert_empty point.fetch(:attributes)
      assert_empty point.fetch(:neutral)
    end

    def test_integration_facade_respects_field_bag_write_capabilities
      replacement = proc { %i[context summary] }

      with_overridden_singleton_method(Julewire::Core::Fields::Bags, :integration_write_sections, replacement) do
        Julewire.with_execution(type: :request, emit_summary: false) do
          assert_nil Julewire::Core::Integration::Facade.add_context(account_id: "acct-1")

          error = assert_raises(ArgumentError) do
            Julewire::Core::Integration::Facade.add_attributes(secret: "nope")
          end

          assert_equal "integration cannot write attributes", error.message
        end
      end
    end

    private

    def emit_cases(entries, strategy:)
      entries.each { emit_case(it, strategy: strategy) }
    end

    def emit_case(entry, strategy:)
      if entry[:execution]
        Julewire.with_execution(type: :request, id: "req-1", emit_summary: false) do
          emit_point(entry, strategy: strategy)
        end
      else
        emit_point(entry, strategy: strategy)
      end
    end

    def emit_point(entry, strategy:)
      return emit_added_point(entry) if strategy == :add

      with_integration_field_overlays(
        context: entry.fetch(:context),
        carry: entry.fetch(:carry),
        attributes: entry.fetch(:attributes),
        neutral: entry.fetch(:neutral)
      ) do
        Julewire.emit(event: entry.fetch(:event), source: entry.fetch(:source))
      end
    end

    def emit_added_point(entry)
      Julewire::Core::Integration::Facade.add_context(entry.fetch(:context))
      Julewire::Core::Integration::Facade.add_carry(trace: { id: "trace-1" })
      Julewire::Core::Integration::Facade.add_attributes(entry.fetch(:attributes))
      Julewire::Core::Integration::Facade.add_neutral(entry.fetch(:neutral))
      Julewire.emit(event: entry.fetch(:event), source: entry.fetch(:source))
    end

    def with_integration_field_overlays(context:, carry:, attributes:, neutral:, &)
      Julewire::Core::Integration::Facade.with_context(context) do
        Julewire::Core::Integration::Facade.with_carry(carry) do
          Julewire::Core::Integration::Facade.with_attributes(attributes) do
            Julewire::Core::Integration::Facade.with_neutral(neutral, &)
          end
        end
      end
    end

    def assert_overlay_point(point, entry)
      context_key, context_value = entry.fetch(:expected_context)
      attribute_path, attribute_value = entry.fetch(:expected_attribute)
      neutral_path, neutral_value = entry.fetch(:expected_neutral)

      assert_equal context_value, point.dig(:context, context_key)
      assert_equal "trace-1", point.dig(:carry, :trace, :id)
      assert_equal attribute_value, point.dig(:attributes, *attribute_path)
      assert_equal neutral_value, point.dig(:neutral, *neutral_path)
    end
  end
end
