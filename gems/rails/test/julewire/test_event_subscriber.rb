# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestEventSubscriber < Minitest::Test
    cover Julewire::Rails::Subscribers::Event
    cover Julewire::Rails::StructuredEventRecord
    cover "Julewire::Rails::ParameterFilters.build"
    cover "Julewire::Rails::Subscribers::Event#emit_event"
    def test_event_subscriber_emits_structured_rails_events
      captured = []
      output = configure_output(captured: captured)
      subscriber = Julewire::Rails::Subscribers::Event.new

      subscriber.emit(
        name: "active_record.sql",
        payload: { sql: "SELECT 1", duration_ms: 1.25 },
        tags: { database: true },
        context: { request_id: "req-1" },
        timestamp: 1_700_000_000_123_456_789,
        source_location: { filepath: "app/models/account.rb", lineno: 12, label: "Account.load" }
      )

      record = parse_records(output).fetch(0)
      raw_record = captured.fetch(0)

      assert_structured_event_record(record)
      assert_equal "SELECT 1", record.dig("attributes", "rails", "sql")
      assert_source_location_attributes(raw_record)
      assert_true record.dig("attributes", "rails", "tags", "database")
      assert_equal "req-1", record.dig("context", "request_id")
      assert_equal "active_record.sql", record.fetch("event")
      assert_equal "rails", record.fetch("source")
      assert_equal "Rails.event", record.fetch("logger")
      assert_equal "point", record.fetch("kind")
    end

    def test_controller_structured_events_enrich_request_summary
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Event.new

      Julewire.with_execution(type: :request, id: "req-1", summary_event: "request.completed") do
        emit_request_started(subscriber)
        Julewire.emit(message: "inside")
        emit_request_completed(subscriber)
      end

      point, summary = parse_records(output)
      rails = summary.fetch("attributes").fetch("rails")

      assert_equal "inside", point.fetch("message")
      assert_nil summary.dig("context", "controller")
      assert_equal "summary", summary.fetch("kind")
      assert_equal "request.completed", summary.fetch("event")
      assert_equal "HomeController", rails.fetch("controller")
      assert_equal "index", rails.fetch("action")
      assert_equal "HTML", rails.fetch("format")
      assert_equal 200, rails.fetch("status")
      assert_in_delta 1.2, rails.fetch("db_runtime")
      assert_in_delta 4.56, rails.fetch("action_runtime_ms")
      assert_false rails.key?("duration_ms")
    end

    def test_controller_structured_events_omit_empty_summary_fields
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Event.new

      Julewire.with_execution(type: :request, id: "req-1", summary_event: "request.completed") do
        subscriber.emit(
          name: "action_controller.request_started",
          payload: { params: {} },
          tags: {},
          context: {}
        )
      end

      summary = parse_records(output).fetch(0)

      assert_false summary.key?("attributes")
    end

    def test_controller_request_start_enriches_summary_without_completion_event
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Event.new

      Julewire.with_execution(type: :request, id: "req-1", summary_event: "request.completed") do
        subscriber.emit(
          name: "action_controller.request_started",
          payload: {
            controller: "HomeController",
            action: nil,
            format: "HTML",
            params: { id: "1" },
            internal: "ignored"
          },
          tags: {},
          context: {}
        )
        Julewire.emit(message: "inside")
      end

      records = parse_records(output)
      summary = records.fetch(1)

      assert_equal 2, records.size
      assert_equal "summary", summary.fetch("kind")
      assert_equal "HomeController", summary.dig("attributes", "rails", "controller")
      assert_equal "1", summary.dig("attributes", "rails", "params", "id")
      assert_false summary.dig("attributes", "rails").key?("action")
      assert_false summary.dig("attributes", "rails").key?("internal")
    end

    def test_controller_request_completed_without_duration_keeps_payload_fields
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Event.new

      Julewire.with_execution(type: :request, id: "req-1", summary_event: "request.completed") do
        Julewire.emit(message: "inside")
        subscriber.emit(
          name: "action_controller.request_completed",
          payload: { status: 204 },
          tags: {},
          context: {}
        )
      end

      point, summary = parse_records(output)

      assert_equal "inside", point.fetch("message")
      assert_equal 204, summary.dig("attributes", "rails", "status")
      assert_false summary.dig("attributes", "rails").key?("action_runtime_ms")
      assert_false summary.dig("attributes", "rails").key?("duration_ms")
    end

    def test_request_events_emit_as_records_without_current_execution
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Event.new

      emit_request_started(subscriber)

      record = parse_records(output).fetch(0)

      assert_equal "action_controller.request_started", record.fetch("event")
      assert_equal "HomeController", record.dig("attributes", "rails", "controller")
    end

    def test_request_completion_events_emit_as_records_without_current_execution
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Event.new

      emit_request_completed(subscriber)

      record = parse_records(output).fetch(0)

      assert_equal "action_controller.request_completed", record.fetch("event")
      assert_equal 200, record.dig("attributes", "rails", "status")
      assert_in_delta(4.56, record.dig("attributes", "rails", "duration_ms"))
    end

    def test_non_request_completion_event_emits_point_record_inside_current_execution
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Event.new

      Julewire.with_execution(type: :request, id: "req-1", summary_event: "request.completed") do
        subscriber.emit(name: "active_record.sql", payload: { sql: "SELECT 1" }, tags: {}, context: {})
      end

      point, summary = parse_records(output)

      assert_equal "point", point.fetch("kind")
      assert_equal "active_record.sql", point.fetch("event")
      assert_equal "SELECT 1", point.dig("attributes", "rails", "sql")
      assert_equal "summary", summary.fetch("kind")
      assert_false summary.fetch("attributes", {}).fetch("rails", {}).key?("sql")
    end

    def test_request_event_names_are_coerced_before_summary_enrichment
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Event.new

      Julewire.with_execution(type: :request, id: "req-1", summary_event: "request.completed") do
        subscriber.emit(
          name: :"action_controller.request_started",
          payload: { params: { id: "1" } },
          tags: {},
          context: {}
        )
        Julewire.emit(message: "inside")
      end

      records = parse_records(output)

      assert_equal 2, records.size
      assert_equal "summary", records.fetch(1).fetch("kind")
      assert_equal "1", records.fetch(1).dig("attributes", "rails", "params", "id")
    end

    def test_event_subscriber_uses_top_level_core_namespace
      output = configure_output
      shadow = Module.new do
        def self.const_missing(_name)
          raise "shadow Core namespace used"
        end
      end

      with_constant(Julewire::Rails, :Core, shadow) do
        Julewire::Rails::Subscribers::Event.new.emit(name: "custom.event", payload: { ok: true })
      end

      assert_true parse_records(output).fetch(0).dig("attributes", "rails", "ok")
    end

    def test_event_subscriber_summary_enrichment_uses_top_level_core_namespace
      output = configure_output
      shadow = Module.new do
        def self.const_missing(_name)
          raise "shadow Core namespace used"
        end
      end

      with_constant(Julewire::Rails, :Core, shadow) do
        Julewire.with_execution(type: :request, id: "req-1", summary_event: "request.completed") do
          emit_request_started(Julewire::Rails::Subscribers::Event.new)
          Julewire.emit(message: "inside")
        end
      end

      assert_equal "1", parse_records(output).fetch(1).dig("attributes", "rails", "params", "id")
    end

    def test_event_subscriber_accepts_event_objects_without_fetch
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Event.new
      event = Object.new
      event.define_singleton_method(:[]) do |key|
        { name: "custom.object_event", payload: { ok: true } }[key]
      end

      subscriber.emit(event)

      assert_true parse_records(output).fetch(0).dig("attributes", "rails", "ok")
    end

    def test_event_subscriber_accepts_nil_prefixes_and_payload_objects
      output = configure_output
      configuration = Julewire::Rails::Configuration.new
      configuration.structured_event_prefixes = nil
      subscriber = Julewire::Rails::Subscribers::Event.new(configuration)
      payload = Object.new
      payload.define_singleton_method(:serialize) { "serialized" }

      assert_true subscriber.accept?(name: "custom.event")
      subscriber.emit(name: "custom.event", payload: payload, tags: "bad", context: "bad")

      record = parse_records(output).fetch(0)

      assert_equal "serialized", record.dig("attributes", "rails", "value")
      assert_false record.key?("tags")
      assert_false record.dig("attributes", "rails").key?("tags")
      assert_false record.key?("context")
    end

    def test_event_subscriber_acceptance_respects_disabled_and_explicit_filters
      configuration = Julewire::Rails::Configuration.new
      subscriber = Julewire::Rails::Subscribers::Event.new(configuration)

      configuration.structured_events = false

      assert_false subscriber.accept?(name: "active_record.sql")

      configuration.structured_events = true
      configuration.structured_event_names = ["custom.allowed"]
      configuration.structured_event_prefixes = ["custom."]
      configuration.structured_event_exclude_names = ["custom.blocked"]
      configuration.structured_event_exclude_prefixes = ["secret."]

      assert_true subscriber.accept?(name: "custom.allowed")
      assert_true subscriber.accept?(name: "custom.other")
      assert_false subscriber.accept?(name: "custom.blocked")
      assert_false subscriber.accept?(name: "secret.event")
      assert_false subscriber.accept?(name: "other.event")
    end

    def test_event_subscriber_filters_serialized_payload_objects_with_rails_filter_parameters
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Event.new
      payload = Object.new
      payload.define_singleton_method(:serialize) { { access_token: "secret", name: "ok" } }

      with_fake_rails_application_filter_parameters([:access_token]) do
        subscriber.emit(name: "custom.event", payload: payload)
      end

      record = parse_records(output).fetch(0)

      assert_equal "[FILTERED]", record.dig("attributes", "rails", "access_token")
      assert_equal "ok", record.dig("attributes", "rails", "name")
    end

    def test_event_subscriber_reads_filter_parameters_from_rails_config
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Event.new
      payload = Object.new
      payload.define_singleton_method(:serialize) { { access_token: "secret", name: "ok" } }
      config = Data.define(:filter_parameters).new(:access_token)
      app = Data.define(:config).new(config)

      with_overridden_singleton_method(::Rails, :application, proc { app }) do
        subscriber.emit(name: "custom.event", payload: payload)
      end

      record = parse_records(output).fetch(0)

      assert_equal "[FILTERED]", record.dig("attributes", "rails", "access_token")
      assert_equal "ok", record.dig("attributes", "rails", "name")
    end

    def test_structured_event_record_compacts_absent_optional_fields
      builder = Julewire::Rails::StructuredEventRecord.new(Julewire::Rails::Configuration.new)
      timestamp = Time.utc(2026, 1, 1, 12, 0, 0)

      record = builder.call(
        { timestamp: timestamp, context: nil, tags: nil, source_location: nil },
        name: "custom.event",
        payload: {}
      )

      assert_equal "2026-01-01T12:00:00.000000000Z", record.fetch(:timestamp)
      assert_equal :info, record.fetch(:severity)
      assert_equal "custom.event", record.fetch(:event)
      assert_equal({}, record.fetch(:neutral))
    end

    def test_structured_event_record_compacts_nil_timestamp
      builder = Julewire::Rails::StructuredEventRecord.new(Julewire::Rails::Configuration.new)

      record = builder.call({ timestamp: nil }, name: "custom.event", payload: {})

      assert_false record.key?(:timestamp)
    end

    def test_structured_event_record_keeps_empty_payload_input_unmutated
      builder = Julewire::Rails::StructuredEventRecord.new(Julewire::Rails::Configuration.new)
      payload = {}

      record = builder.call(
        { tags: { request_id: "req-1" } },
        name: "custom.event",
        payload: payload
      )

      assert_empty payload
      assert_equal "req-1", record.dig(:attributes, :rails, :tags, :request_id)
    end

    def test_structured_event_record_payload_hash_contracts
      builder = Julewire::Rails::StructuredEventRecord.new(Julewire::Rails::Configuration.new)
      hash_subclass = Class.new(Hash).new
      hash_subclass["kind"] = "subclass"
      serialized_hash = Object.new
      serialized_hash.define_singleton_method(:serialize) { { "access_token" => "secret", "name" => "ok" } }
      serialized_hash_subclass = Object.new
      serialized_hash_subclass.define_singleton_method(:serialize) { hash_subclass }
      serialized_scalar = Object.new
      serialized_scalar.define_singleton_method(:serialize) { "serialized" }
      plain_object = Object.new

      hash_payload = builder.payload_hash(serialized_hash)
      hash_subclass_payload = builder.payload_hash(serialized_hash_subclass)
      scalar_payload = builder.payload_hash(serialized_scalar)
      object_payload = builder.payload_hash(plain_object)

      assert_equal({}, builder.payload_hash(nil))
      assert_equal "secret", hash_payload.fetch(:access_token)
      assert_equal "ok", hash_payload.fetch(:name)
      assert_equal "subclass", hash_subclass_payload.fetch(:kind)
      assert_equal "serialized", scalar_payload.fetch(:value)
      assert_same plain_object, object_payload.fetch(:value)
      assert_false object_payload.key?(:serialize_error_class)
    end

    def test_structured_event_record_payload_filter_override_contracts
      configuration = Julewire::Rails::Configuration.new
      filter = Object.new
      filter.define_singleton_method(:filter) { |payload| payload.merge("access_token" => "[FILTERED]") }
      builder = Julewire::Rails::StructuredEventRecord.new(configuration, parameter_filter: filter)
      payload = Object.new
      payload.define_singleton_method(:serialize) { { "access_token" => "secret", "name" => "ok" } }

      filtered = builder.payload_hash(payload)

      assert_equal "[FILTERED]", filtered.fetch(:access_token)
      assert_equal "ok", filtered.fetch(:name)
    end

    def test_structured_event_record_filter_keeps_payload_for_non_hash_filter_result
      configuration = Julewire::Rails::Configuration.new
      filter = Object.new
      filter.define_singleton_method(:filter) { |_payload| "not a hash" }
      builder = Julewire::Rails::StructuredEventRecord.new(configuration, parameter_filter: filter)
      payload = Object.new
      payload.define_singleton_method(:serialize) { { "access_token" => "secret" } }

      filtered = builder.payload_hash(payload)

      assert_equal "secret", filtered.fetch(:access_token)
    end

    def test_structured_event_record_accepts_hash_subclass_filter_result
      hash_class = Class.new(Hash)
      configuration = Julewire::Rails::Configuration.new
      filter = Object.new
      filter.define_singleton_method(:filter) { |_payload| hash_class["filtered" => true] }
      builder = Julewire::Rails::StructuredEventRecord.new(configuration, parameter_filter: filter)
      payload = Object.new
      payload.define_singleton_method(:serialize) { { "filtered" => false } }

      filtered = builder.payload_hash(payload)

      assert_true filtered.fetch(:filtered)
    end

    def test_structured_event_record_severity_contracts
      builder = Julewire::Rails::StructuredEventRecord.new(Julewire::Rails::Configuration.new)

      assert_equal :debug,
                   builder.call({}, name: "action_controller.unpermitted_parameters", payload: {}).fetch(:severity)
      assert_equal :debug, builder.call({}, name: "action_view.render_template", payload: {}).fetch(:severity)
      assert_equal :debug, builder.call({}, name: "active_record.sql", payload: {}).fetch(:severity)
      assert_equal :info, builder.call({}, name: "custom.event", payload: {}).fetch(:severity)
    end

    def test_structured_event_record_uses_top_level_core_values
      shadow = Module.new do
        def self.const_missing(_name)
          raise "shadow Core namespace used"
        end

        const_set(
          :Integration,
          Module.new do
            def self.const_missing(_name)
              raise "shadow Core namespace used"
            end
          end
        )
      end

      with_constant(Julewire::Rails, :Core, shadow) do
        builder = Julewire::Rails::StructuredEventRecord.new(Julewire::Rails::Configuration.new)
        payload = Object.new
        payload.define_singleton_method(:serialize) { { "name" => "ok" } }
        scalar_payload = Object.new
        scalar_payload.define_singleton_method(:serialize) { "serialized" }
        plain_payload = Object.new
        broken_payload = Object.new
        broken_payload.define_singleton_method(:serialize) { raise "boom" }
        record = builder.call({ tags: { request_id: "req-1" } }, name: "custom.event", payload: {})

        assert_equal "req-1", record.dig(:attributes, :rails, :tags, :request_id)
        assert_equal 1, builder.payload_hash("count" => 1).fetch(:count)
        assert_equal "ok", builder.payload_hash(payload).fetch(:name)
        assert_equal "serialized", builder.payload_hash(scalar_payload).fetch(:value)
        plain_payload_hash = builder.payload_hash(plain_payload)

        assert_same plain_payload, plain_payload_hash.fetch(:value)
        assert_false plain_payload_hash.key?(:serialize_error_class)
        assert_equal "RuntimeError", builder.payload_hash(broken_payload).fetch(:serialize_error_class)
      end
    end

    def test_event_subscriber_can_disable_serialized_payload_object_filtering
      output = configure_output
      configuration = Julewire::Rails::Configuration.new
      configuration.filter_event_payloads = false
      subscriber = Julewire::Rails::Subscribers::Event.new(configuration)
      payload = Object.new
      payload.define_singleton_method(:serialize) { { access_token: "secret" } }

      with_fake_rails_application_filter_parameters([:access_token]) do
        subscriber.emit(name: "custom.event", payload: payload)
      end

      assert_equal "secret", parse_records(output).fetch(0).dig("attributes", "rails", "access_token")
    end

    def test_event_subscriber_keeps_serialized_payload_when_filter_is_unavailable
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Event.new
      payload = Object.new
      payload.define_singleton_method(:serialize) { { access_token: "secret" } }

      with_fake_rails_application_filter_parameters([]) do
        subscriber.emit(name: "custom.event", payload: payload)
      end

      assert_equal "secret", parse_records(output).fetch(0).dig("attributes", "rails", "access_token")
    end

    def test_event_subscriber_contains_payload_filter_failures
      filter = Object.new
      builder = Julewire::Rails::StructuredEventRecord.new(Julewire::Rails::Configuration.new, parameter_filter: filter)
      payload = Object.new
      payload.define_singleton_method(:serialize) { { access_token: "secret" } }
      filter.define_singleton_method(:filter) { raise "filter failed" }

      record = builder.call(
        { name: "custom.event", payload: payload },
        name: "custom.event",
        payload: builder.payload_hash(payload)
      )

      assert_equal "secret", record.dig(:attributes, :rails, :access_token)
    end

    def test_event_subscriber_handles_nil_and_scalar_payloads
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Event.new

      subscriber.emit(name: "custom.nil", payload: nil, tags: {}, context: {})
      subscriber.emit(name: "custom.scalar", payload: Object.new, tags: {}, context: {})

      nil_record, scalar_record = parse_records(output)

      assert_false nil_record.key?("payload")
      assert_match(/Object/, scalar_record.dig("attributes", "rails", "value"))
    end

    def test_event_subscriber_handles_payload_serialization_errors_and_debug_events
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Event.new
      payload = Object.new
      payload.define_singleton_method(:serialize) { raise "serialize failed" }

      subscriber.emit(name: "action_controller.unpermitted_parameters", payload: payload)

      record = parse_records(output).fetch(0)

      assert_equal "debug", record.fetch("severity")
      assert_match(/Object/, record.dig("attributes", "rails", "value"))
      assert_equal "RuntimeError", record.dig("attributes", "rails", "serialize_error_class")
    end

    def test_event_subscriber_records_adapter_failures
      subscriber = Julewire::Rails::Subscribers::Event.new
      bad_event = Object.new
      bad_event.define_singleton_method(:[]) { |_key| raise "bad event" }

      assert_nil subscriber.emit(bad_event)

      health = Julewire.health
      integration = health.dig(:process_integrations, :rails)

      assert_equal :degraded, health.fetch(:status)
      assert_equal :degraded, integration.fetch(:status)
      assert_equal 1, integration.dig(:counts, :failures)
      assert_equal :event_subscriber, integration.dig(:last_failure, :component)
      assert_equal :emit, integration.dig(:last_failure, :action)
      assert_equal "RuntimeError", integration.dig(:last_failure, :class)
      refute_includes integration.fetch(:last_failure), :message
    end

    private

    def assert_structured_event_record(record)
      assert_equal "debug", record.fetch("severity")
      assert_equal "active_record.sql", record.fetch("event")
      assert_equal "Rails.event", record.fetch("logger")
      assert_equal "rails", record.fetch("source")
    end

    def assert_source_location_attributes(record)
      assert_equal "app/models/account.rb", record.dig(:neutral, :"code.file.path")
      assert_equal 12, record.dig(:neutral, :"code.line.number")
      assert_equal "Account.load", record.dig(:neutral, :"code.function.name")
    end
  end

  class TestEventSubscriberInstall < Minitest::Test
    cover Julewire::Rails::Subscribers::Event
    cover Julewire::Rails::StructuredEventRecord
    def test_event_subscriber_install_is_idempotent
      reporter = Object.new
      subscriptions = []
      unsubscriptions = []
      reporter.define_singleton_method(:subscribe) { |subscriber, &block| subscriptions << [subscriber, block] }
      reporter.define_singleton_method(:unsubscribe) { unsubscriptions << it }
      configuration = Julewire::Rails::Configuration.new
      next_configuration = Julewire::Rails::Configuration.new
      next_configuration.structured_event_prefixes = ["custom."]
      disabled_configuration = Julewire::Rails::Configuration.new
      disabled_configuration.structured_events = false

      with_fake_event_subscriber_install(reporter) do
        first = Julewire::Rails::Subscribers::Event.install!(configuration)
        second = Julewire::Rails::Subscribers::Event.install!(next_configuration)

        assert_same first, second
        assert_true second.accept?(name: "custom.event")
        assert_false second.accept?(name: "active_record.sql")

        assert_nil Julewire::Rails::Subscribers::Event.install!(disabled_configuration)
        refute_predicate Julewire::Rails::Subscribers::Event, :installed?
        assert_equal [first], unsubscriptions
      end

      assert_equal 1, subscriptions.length
    end

    def test_event_subscriber_installs_against_current_rails_event_catalog
      subscriber = Julewire::Rails::Subscribers::Event.install!(Julewire::Rails::Configuration.new)

      assert_instance_of Julewire::Rails::Subscribers::Event, subscriber
      assert_predicate Julewire::Rails::Subscribers::Event, :installed?
    ensure
      Julewire::Rails::Subscribers::Event.reset!
    end

    def test_event_subscriber_install_requires_structured_event_paths_before_subscribing
      Julewire::Rails::Subscribers::Event.reset!
      reporter = Object.new
      reporter.define_singleton_method(:subscribe) { |_subscriber, &_block| nil }
      reporter.define_singleton_method(:unsubscribe) { |_subscriber| nil }
      required = []
      subscribed_after_requires = nil
      subscription_filter = nil
      configuration = Julewire::Rails::Configuration.new
      configuration.structured_event_prefixes = ["allowed."]

      with_overridden_singleton_method(
        Julewire::Core::Integration::Lifecycle,
        :require_optional,
        proc { |path| required << path }
      ) do
        with_overridden_singleton_method(
          Julewire::RailsSupport::EventReporter,
          :default,
          proc { reporter }
        ) do
          with_overridden_singleton_method(
            Julewire::RailsSupport::EventReporter,
            :subscribe,
            proc { |_reporter, subscriber, &block|
              subscribed_after_requires = required.dup
              subscription_filter = block
              -> { reporter.unsubscribe(subscriber) }
            }
          ) do
            with_shadowed_nested_rails_support do
              Julewire::Rails::Subscribers::Event.install!(configuration)
            end
          end
        end
      end

      assert_equal Julewire::Rails::Subscribers::Event::STRUCTURED_EVENT_FILES, subscribed_after_requires
      assert_true subscription_filter.call(name: "allowed.event")
      assert_false subscription_filter.call(name: "blocked.event")
    ensure
      Julewire::Rails::Subscribers::Event.reset!
    end

    def test_event_subscriber_install_skips_non_subscribable_reporter
      Julewire::Rails::Subscribers::Event.reset!
      reporter = Object.new

      with_overridden_singleton_method(
        Julewire::Rails::Subscribers::Event,
        :require_structured_event_subscribers,
        proc {}
      ) do
        with_overridden_singleton_method(
          Julewire::RailsSupport::EventReporter,
          :default,
          proc { reporter }
        ) do
          with_shadowed_nested_rails_support do
            assert_nil Julewire::Rails::Subscribers::Event.install!(Julewire::Rails::Configuration.new)
          end
        end
      end

      refute_predicate Julewire::Rails::Subscribers::Event, :installed?
    ensure
      Julewire::Rails::Subscribers::Event.reset!
    end

    def test_event_subscriber_receives_current_rails_event_reporter_events
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Event.install!(Julewire::Rails::Configuration.new)

      ::Rails.event.notify("active_record.sql", sql: "SELECT 1", duration_ms: 1.25)

      record = parse_records(output).fetch(0)

      assert_instance_of Julewire::Rails::Subscribers::Event, subscriber
      assert_equal "active_record.sql", record.fetch("event")
      assert_equal "SELECT 1", record.dig("attributes", "rails", "sql")
    ensure
      Julewire::Rails::Subscribers::Event.reset!
    end

    def test_structured_event_subscriber_paths_resolve_against_current_rails
      Julewire::Rails::Subscribers::Event::STRUCTURED_EVENT_FILES.each do |path|
        refute_nil Julewire::Core::Integration::Lifecycle.require_optional(path), "#{path} should resolve"
      end
    end

    private

    def with_fake_event_subscriber_install(reporter, &)
      Julewire::Rails::Subscribers::Event.reset!
      empty_require = proc {}

      with_overridden_singleton_method(::Rails, :event, proc { reporter }) do
        with_overridden_singleton_method(
          Julewire::Rails::Subscribers::Event,
          :require_structured_event_subscribers,
          empty_require, &
        )
      end
    ensure
      Julewire::Rails::Subscribers::Event.reset!
    end
  end
end
