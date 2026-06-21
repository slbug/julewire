# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestEventSubscriber < Minitest::Test
    cover Julewire::Rails::Subscribers::Event

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
      assert record.dig("attributes", "rails", "tags", "database")
      assert_equal "req-1", record.dig("context", "request_id")
      assert_julewire_record_source_contract(
        records: [record],
        event: "active_record.sql",
        source: "rails",
        logger: "Rails.event",
        kind: "point"
      )
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

      assert_equal "inside", point.fetch("message")
      assert_nil summary.dig("context", "controller")
      assert_equal expected_controller_summary_fields, controller_summary_fields(summary)
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

      refute summary.key?("attributes")
    end

    def test_event_subscriber_accepts_nil_prefixes_and_payload_objects
      output = configure_output
      configuration = Julewire::Rails::Configuration.new
      configuration.structured_event_prefixes = nil
      subscriber = Julewire::Rails::Subscribers::Event.new(configuration)
      payload = Object.new
      payload.define_singleton_method(:serialize) { "serialized" }

      assert subscriber.accept?(name: "custom.event")
      subscriber.emit(name: "custom.event", payload: payload, tags: "bad", context: "bad")

      record = parse_records(output).fetch(0)

      assert_equal "serialized", record.dig("attributes", "rails", "value")
      refute record.key?("tags")
      refute record.dig("attributes", "rails").key?("tags")
      refute record.key?("context")
    end

    def test_event_subscriber_acceptance_respects_disabled_and_explicit_filters
      configuration = Julewire::Rails::Configuration.new
      subscriber = Julewire::Rails::Subscribers::Event.new(configuration)

      configuration.structured_events = false

      refute subscriber.accept?(name: "active_record.sql")

      configuration.structured_events = true
      configuration.structured_event_names = ["custom.allowed"]
      configuration.structured_event_prefixes = ["custom."]
      configuration.structured_event_exclude_names = ["custom.blocked"]
      configuration.structured_event_exclude_prefixes = ["secret."]

      assert subscriber.accept?(name: "custom.allowed")
      assert subscriber.accept?(name: "custom.other")
      refute subscriber.accept?(name: "custom.blocked")
      refute subscriber.accept?(name: "secret.event")
      refute subscriber.accept?(name: "other.event")
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

      refute nil_record.key?("payload")
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

      _health, integration = assert_julewire_integration_failure_contract(
        integration: :rails,
        component: :event_subscriber,
        exercise: -> { subscriber.emit(bad_event) }
      )

      assert_equal :emit, integration.dig(:last_failure, :action)
      assert_equal "RuntimeError", integration.dig(:last_failure, :class)
    end

    def test_event_subscriber_contains_chaos_failures
      Julewire::Testing::Chaos.assert_emitter_chaos_contract(
        self,
        component: :rails_event_subscriber,
        build: ->(_error) { Julewire::Rails::Subscribers::Event.new },
        exercise: ->(subscriber, error) { subscriber.emit(raising_event(error)) }
      )
    end

    private

    def raising_event(error)
      Object.new.tap do |event|
        event.define_singleton_method(:[]) { |_key| raise error }
      end
    end

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
        assert second.accept?(name: "custom.event")
        refute second.accept?(name: "active_record.sql")

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
      rails_singleton = class << ::Rails; self; end
      original_event = rails_singleton.instance_method(:event)
      verbose = $VERBOSE
      $VERBOSE = nil
      Julewire::Rails::Subscribers::Event.reset!
      rails_singleton.define_method(:event) { reporter }
      empty_require = proc {}

      with_overridden_singleton_method(
        Julewire::Rails::Subscribers::Event,
        :require_structured_event_subscribers,
        empty_require, &
      )
    ensure
      rails_singleton&.define_method(:event, original_event)
      $VERBOSE = verbose
      Julewire::Rails::Subscribers::Event.reset!
    end
  end
end
