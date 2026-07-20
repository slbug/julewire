# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestIntegrationFieldOverlays < Minitest::Test
    cover Julewire::Core::Integration::Facade
    cover Julewire::Core::Fields::Bags
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

    def test_with_field_overlays_reject_non_hash_fields
      {
        with_context: nil,
        with_carry: "trace-1",
        with_attributes: Object.new,
        with_neutral: false
      }.each do |method_name, fields|
        error = assert_raises(TypeError, method_name.to_s) do
          Julewire::Core::Integration::Facade.public_send(method_name, fields) { flunk "invalid owned input yielded" }
        end

        assert_equal "owned data must be a Hash", error.message
      end
    end

    def test_with_field_overlays_require_blocks
      %i[with_context with_carry with_attributes with_neutral].each do |method_name|
        error = assert_raises(ArgumentError) do
          Julewire::Core::Integration::Facade.public_send(method_name, {})
        end

        assert_equal "block required", error.message
      end
    end

    def test_integration_field_helpers_reject_non_symbol_keys
      assert_integration_owned_fields_rejected(
        { account: { "id" => "acct-1" } },
        "record must not use string keys"
      )
      assert_integration_owned_fields_rejected(
        { account: { Object.new => "acct-1" } },
        "record keys must be Symbols"
      )
    end

    def test_with_field_overlays_treat_fields_as_owned
      metadata = fixture_truncation_metadata

      records = capture_julewire_records do
        Julewire::Core::Integration::Facade.with_context(_julewire_truncation: metadata) do
          Julewire::Core::Integration::Facade.with_carry(_julewire_truncation: metadata) do
            Julewire::Core::Integration::Facade.with_attributes(_julewire_truncation: metadata) do
              Julewire::Core::Integration::Facade.with_neutral(_julewire_truncation: metadata) do
                Julewire.emit(event: "owned.fields", source: "test")
              end
            end
          end
        end
      end

      point = records.fetch(0)

      assert_owned_truncation_metadata_sections(point)
    end

    def test_add_field_overlays_treat_fields_as_owned
      metadata = fixture_truncation_metadata

      records = capture_julewire_records do
        Julewire::Core::Integration::Facade.add_context(_julewire_truncation: metadata)
        Julewire::Core::Integration::Facade.add_carry(_julewire_truncation: metadata)
        Julewire::Core::Integration::Facade.add_attributes(_julewire_truncation: metadata)
        Julewire::Core::Integration::Facade.add_neutral(_julewire_truncation: metadata)
        Julewire.emit(event: "owned.added.fields", source: "test")
      end

      point = records.fetch(0)

      assert_owned_truncation_metadata_sections(point)
    end

    def test_with_field_overlays_delegate_to_owned_context_store_sections
      probe = OverlayStoreProbe.new

      with_overridden_singleton_method(Julewire::Core::ContextStore, :current, proc { probe }) do
        assert_equal :context, Julewire::Core::Integration::Facade.with_context({ request_id: "req-1" }) { :context }
        assert_equal :carry, Julewire::Core::Integration::Facade.with_carry({ trace: { id: "trace-1" } }) { :carry }
        assert_equal :attributes,
                     Julewire::Core::Integration::Facade.with_attributes({ account: { id: "acct-1" } }) { :attributes }
        assert_equal :neutral,
                     Julewire::Core::Integration::Facade.with_neutral({ http: { method: "GET" } }) { :neutral }
      end

      assert_equal expected_owned_overlay_calls, probe.calls
    end

    def test_add_field_overlays_delegate_to_owned_context_store_sections
      probe = OverlayStoreProbe.new

      with_overridden_singleton_method(Julewire::Core::ContextStore, :current, proc { probe }) do
        assert_nil Julewire::Core::Integration::Facade.add_context({ request_id: "req-1" })
        assert_nil Julewire::Core::Integration::Facade.add_carry({ trace: { id: "trace-1" } })
        assert_nil Julewire::Core::Integration::Facade.add_attributes({ account: { id: "acct-1" } })
        assert_nil Julewire::Core::Integration::Facade.add_neutral({ http: { method: "GET" } })
      end

      assert_equal expected_owned_overlay_calls, probe.calls
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

    def test_integration_facade_overlay_respects_field_bag_write_capabilities
      replacement = proc { %i[context summary] }

      with_overridden_singleton_method(Julewire::Core::Fields::Bags, :integration_write_sections, replacement) do
        error = assert_raises(ArgumentError) do
          Julewire::Core::Integration::Facade.with_attributes(secret: "nope") { :unused }
        end

        assert_equal "integration cannot write attributes", error.message
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

    def assert_owned_truncation_metadata_sections(record)
      %i[context carry attributes neutral].each do |section|
        assert_equal ["ids"], record.dig(section, :_julewire_truncation, :truncated_fields)
      end
    end

    def expected_owned_overlay_calls
      [
        [:context, { request_id: "req-1" }, true],
        [:carry, { trace: { id: "trace-1" } }, true],
        [:attributes, { account: { id: "acct-1" } }, true],
        [:neutral, { http: { method: "GET" } }, true]
      ]
    end

    def assert_integration_owned_fields_rejected(fields, message)
      %i[add_context add_carry add_attributes add_neutral].each do |method_name|
        assert_raises_message(TypeError, message) { Julewire::Core::Integration::Facade.public_send(method_name, fields) }
      end

      %i[with_context with_carry with_attributes with_neutral].each do |method_name|
        assert_raises_message(TypeError, message) do
          Julewire::Core::Integration::Facade.public_send(method_name, fields) { :unreachable }
        end
      end

      assert_raises_message(TypeError, message) do
        Julewire::Core::Integration::Facade.with_execution(type: :job, attributes: fields) { :unreachable }
      end

      Julewire.with_execution(type: :job, emit_summary: false) do
        %i[add_summary_attributes add_summary_neutral].each do |method_name|
          assert_raises_message(TypeError, message) { Julewire::Core::Integration::Facade.public_send(method_name, fields) }
        end
      end
    end

    class OverlayStoreProbe
      attr_reader :calls

      def initialize
        @calls = []
      end

      def with_context(fields, owned:, &)
        call_section(:context, fields, owned, &)
      end

      def with_carry(fields, owned:, &)
        call_section(:carry, fields, owned, &)
      end

      def with_attributes(fields, owned:, &)
        call_section(:attributes, fields, owned, &)
      end

      def with_neutral(fields, owned:, &)
        call_section(:neutral, fields, owned, &)
      end

      def add_context(fields, owned:)
        record_section(:context, fields, owned)
      end

      def add_carry(fields, owned:)
        record_section(:carry, fields, owned)
      end

      def add_attributes(fields, owned:)
        record_section(:attributes, fields, owned)
      end

      def add_neutral(fields, owned:)
        record_section(:neutral, fields, owned)
      end

      private

      def call_section(section, fields, owned)
        @calls << [section, fields, owned]
        yield
      end

      def record_section(section, fields, owned)
        @calls << [section, fields, owned]
        nil
      end
    end
  end
end
