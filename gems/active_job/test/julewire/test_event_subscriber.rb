# frozen_string_literal: true

require "support/active_job_test_support"

module Julewire
  class TestActiveJobEventSubscriber < Minitest::Test
    cover Julewire::ActiveJob::Subscribers::Event
    cover Julewire::ActiveJob::JobAttributes
    include ActiveJobTestSupport

    def test_event_subscriber_rejects_when_structured_events_are_disabled
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.structured_events = false
      subscriber = Julewire::ActiveJob::Subscribers::Event.new(configuration)

      assert_false subscriber.accept?(name: "active_job.perform")
    end

    def test_event_subscriber_rejects_missing_event_name
      subscriber = Julewire::ActiveJob::Subscribers::Event.new

      assert_false subscriber.accept?({})
    end

    def test_event_subscriber_accepts_any_configured_prefix
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.event_prefixes = ["custom.", "active_job."]
      subscriber = Julewire::ActiveJob::Subscribers::Event.new(configuration)

      assert_true subscriber.accept?(name: "active_job.started")
      assert_true subscriber.accept?(name: "custom.started")
      assert_false subscriber.accept?(name: "other.started")
    end

    def test_event_subscriber_accepts_scalar_prefix_configuration
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.event_prefixes = "active_job."
      subscriber = Julewire::ActiveJob::Subscribers::Event.new(configuration)

      assert_true subscriber.accept?(name: "active_job.started")
      assert_false subscriber.accept?(name: "other.started")
    end

    def test_event_subscriber_install_resets_existing_subscription_when_disabled
      reporter = FakeReporter.new
      configuration = Julewire::ActiveJob::Configuration.new
      disabled_configuration = Julewire::ActiveJob::Configuration.new
      disabled_configuration.structured_events = false
      required = []

      Julewire::ActiveJob::Subscribers::Event.reset!
      with_overridden_singleton_method(Julewire::Core::Integration::Lifecycle, :require_optional, proc { |path|
        required << path
      }) do
        subscriber = Julewire::ActiveJob::Subscribers::Event.install!(configuration, event_reporter: reporter)

        assert_nil Julewire::ActiveJob::Subscribers::Event.install!(disabled_configuration, event_reporter: reporter)
        assert_equal [subscriber], reporter.unsubscriptions
      end
      assert_equal [Julewire::ActiveJob::Subscribers::Event::STRUCTURED_EVENT_FILE], required
    ensure
      Julewire::ActiveJob::Subscribers::Event.reset!
    end

    def test_event_subscriber_installs_against_current_active_job_event_catalog
      assert_predicate self, :active_support_event_reporter?,
                       "Active Job 8.1 should expose ActiveSupport.event_reporter"

      subscriber = Julewire::ActiveJob::Subscribers::Event.install!(Julewire::ActiveJob::Configuration.new)

      assert_instance_of Julewire::ActiveJob::Subscribers::Event, subscriber
      assert_predicate Julewire::ActiveJob::Subscribers::Event, :installed?
    ensure
      Julewire::ActiveJob::Subscribers::Event.reset!
    end

    def test_event_subscriber_receives_current_active_job_event_reporter_events
      assert_predicate self, :active_support_event_reporter?,
                       "Active Job 8.1 should expose ActiveSupport.event_reporter"

      previous_adapter = ::ActiveJob::Base.queue_adapter
      ::ActiveJob::Base.queue_adapter = :inline
      Julewire::ActiveJob.install!(base: ::ActiveJob::Base)
      records = capture_records

      with_real_active_job_class(:ActiveJobStructuredEventCanary, &:perform_later)

      assert_active_job_structured_events(records.map { it[:event] })
    ensure
      ::ActiveJob::Base.queue_adapter = previous_adapter if defined?(previous_adapter)
      Julewire::ActiveJob::Subscribers::Event.reset!
    end

    def test_event_subscriber_accepts_nil_prefixes_and_wraps_scalar_payloads
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.event_prefixes = nil
      subscriber = Julewire::ActiveJob::Subscribers::Event.new(configuration)
      records = capture_records

      assert_true subscriber.accept?(name: "other.event")
      subscriber.emit(
        name: "other.event",
        payload: "value",
        timestamp: Object.new,
        tags: "bad",
        context: "bad",
        source_location: { filepath: "app/jobs/import_job.rb", lineno: 42, label: "ImportJob#perform" }
      )

      record = records.fetch(0)

      assert_equal "other.event", record.fetch(:event)
      assert_equal "active_job", record.fetch(:source)
      assert_equal "ActiveJob.event", record.fetch(:logger)
      assert_equal :point, record.fetch(:kind)
      assert_equal({ value: "value" }, active_job_attributes(record))
      assert_equal "app/jobs/import_job.rb", record.dig(:neutral, :"code.file.path")
      assert_equal 42, record.dig(:neutral, :"code.line.number")
      assert_equal "ImportJob#perform", record.dig(:neutral, :"code.function.name")
      assert_false record.key?(:tags)
      assert_false active_job_attributes(record).key?(:tags)
      assert_empty record.fetch(:context)
    end

    def test_event_subscriber_accepts_symbol_event_names
      subscriber = Julewire::ActiveJob::Subscribers::Event.new
      records = capture_records

      assert_true subscriber.accept?(name: :"active_job.started")
      subscriber.emit(name: :"active_job.started", payload: { job_class: "SymbolJob" })

      record = records.fetch(0)

      assert_equal "active_job.started", record.fetch(:event)
      assert_equal :info, record.fetch(:severity)
      assert_equal "SymbolJob", active_job_attributes(record).fetch(:job_class)
    end

    def test_event_subscriber_marks_symbol_error_event_names
      subscriber = Julewire::ActiveJob::Subscribers::Event.new
      records = capture_records

      subscriber.emit(name: :"active_job.discarded")

      record = records.fetch(0)

      assert_equal "active_job.discarded", record.fetch(:event)
      assert_equal :error, record.fetch(:severity)
    end

    def test_event_subscriber_treats_missing_payload_as_empty
      subscriber = Julewire::ActiveJob::Subscribers::Event.new
      records = capture_records

      subscriber.emit(name: "active_job.started")

      assert_equal({}, active_job_attributes(records.fetch(0)))
    end

    def test_event_subscriber_omits_error_for_non_exception_payloads
      subscriber = Julewire::ActiveJob::Subscribers::Event.new
      records = capture_records

      subscriber.emit(name: "active_job.started", payload: { job_class: "ImportJob" })

      record = records.fetch(0)

      assert_equal :info, record.fetch(:severity)
      assert_nil record.fetch(:error)
    end

    def test_event_subscriber_adds_tags_to_nil_payload
      subscriber = Julewire::ActiveJob::Subscribers::Event.new
      records = capture_records

      subscriber.emit(
        name: "active_job.started",
        payload: nil,
        tags: { tenant: "acme" }
      )

      assert_equal({ tenant: "acme" }, active_job_attributes(records.fetch(0)).fetch(:tags))
    end

    def test_event_subscriber_marks_error_events
      subscriber = Julewire::ActiveJob::Subscribers::Event.new
      records = capture_records

      subscriber.emit(name: "active_job.discarded", payload: nil)

      assert_equal :error, records.fetch(0).fetch(:severity)
      assert_equal({}, records.fetch(0).fetch(:payload))
      assert_equal({}, active_job_attributes(records.fetch(0)))
    end

    def test_event_subscriber_marks_exception_payloads_as_error
      subscriber = Julewire::ActiveJob::Subscribers::Event.new
      records = capture_records

      payload = Class.new(Hash).new
      payload[:exception_class] = "ActiveJob::EnqueueError"
      payload[:exception_message] = "boom"

      subscriber.emit(
        name: "active_job.enqueued",
        payload: payload
      )

      record = records.fetch(0)

      assert_equal :error, record.fetch(:severity)
      assert_equal "ActiveJob::EnqueueError", active_job_attributes(record).fetch(:exception_class)
      assert_equal(
        { class: "ActiveJob::EnqueueError", message: "boom" },
        record.fetch(:error)
      )
      assert_equal "active_job", record.dig(:neutral, :"job.system")
    end

    def test_event_subscriber_marks_exception_message_only_payloads_as_error
      subscriber = Julewire::ActiveJob::Subscribers::Event.new
      records = capture_records

      subscriber.emit(
        name: "active_job.enqueued",
        payload: { exception_message: "boom" }
      )

      assert_equal :error, records.fetch(0).fetch(:severity)
      assert_equal({ message: "boom" }, records.fetch(0).fetch(:error))
    end

    def test_event_subscriber_marks_exception_backtrace_only_payloads_as_error
      subscriber = Julewire::ActiveJob::Subscribers::Event.new
      records = capture_records
      backtrace = ["app/jobs/import_job.rb:42"]

      subscriber.emit(
        name: "active_job.enqueued",
        payload: { exception_backtrace: backtrace }
      )

      assert_equal :error, records.fetch(0).fetch(:severity)
      assert_equal({ backtrace: backtrace }, records.fetch(0).fetch(:error))
    end

    def test_event_subscriber_emits_context_timestamp_source_and_tags
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.source = "jobs"
      subscriber = Julewire::ActiveJob::Subscribers::Event.new(configuration)
      records = capture_records

      subscriber.emit(
        name: "active_job.started",
        payload: { job_class: "ImportJob", job_id: "job-2" },
        timestamp: Time.utc(2026, 1, 1, 0, 0, 1),
        tags: { tenant: "acme" },
        context: { request_id: "request-2" }
      )

      record = records.fetch(0)

      assert_equal "jobs", record.fetch(:source)
      assert_equal "2026-01-01T00:00:01.000000000Z", record.fetch(:timestamp)
      assert_equal({ request_id: "request-2" }, record.fetch(:context))
      assert_equal({ tenant: "acme" }, active_job_attributes(record).fetch(:tags))
      assert_equal "ImportJob", active_job_attributes(record).fetch(:job_class)
      assert_equal "job-2", active_job_attributes(record).fetch(:job_id)
      assert_equal "ImportJob", record.dig(:neutral, :"job.name")
      assert_equal "job-2", record.dig(:neutral, :"job.id")
    end

    def test_event_subscriber_preserves_exception_backtrace_on_error_records
      subscriber = Julewire::ActiveJob::Subscribers::Event.new
      records = capture_records

      subscriber.emit(
        name: "active_job.completed",
        payload: {
          exception_class: "RuntimeError",
          exception_message: "boom",
          exception_backtrace: ["app/jobs/import_job.rb:42:in 'ImportJob#perform'"]
        }
      )

      assert_equal(
        {
          class: "RuntimeError",
          message: "boom",
          backtrace: ["app/jobs/import_job.rb:42:in 'ImportJob#perform'"]
        },
        records.fetch(0).fetch(:error)
      )
    end

    def test_event_subscriber_ignores_unknown_continuation_events_for_summary
      records = capture_records

      emit_active_job_event(name: "active_job.custom_continuation", payload: { step: "unknown", cursor: 1 })

      summary = records.find { it[:kind] == :summary }

      assert_false active_job_attributes(summary).key?(:continuation_last_step)
      assert_false active_job_attributes(summary).key?(:continuation_steps_started)
    end

    def test_event_subscriber_records_adapter_failures
      subscriber = Julewire::ActiveJob::Subscribers::Event.new
      bad_event = Object.new
      bad_event.define_singleton_method(:[]) { |_key| raise "bad event" }

      assert_nil subscriber.emit(bad_event)

      health = Julewire.health
      integration = health.dig(:process_integrations, :active_job)

      assert_equal :degraded, health.fetch(:status)
      assert_equal :degraded, integration.fetch(:status)
      assert_equal 1, integration.dig(:counts, :failures)
      assert_equal :event_subscriber, integration.dig(:last_failure, :component)
      assert_equal :emit, integration.dig(:last_failure, :action)
      assert_equal "RuntimeError", integration.dig(:last_failure, :class)
      refute_includes integration.fetch(:last_failure), :message
    end

    def test_job_attributes_handles_event_payload_keys_and_non_hash_input
      attributes = Julewire::ActiveJob::JobAttributes.call(
        class_name: "EventPayloadJob",
        id: "job-event",
        provider_job_id: "provider-1",
        queue_name: "critical",
        priority: 10,
        executions: 3,
        enqueued_at: "2026-01-01T00:00:00Z",
        scheduled_at: "2026-01-01T00:05:00Z",
        status: "ok"
      )

      neutral = attributes

      assert_equal "EventPayloadJob", neutral.fetch(:"job.name")
      assert_equal "job-event", neutral.fetch(:"job.id")
      assert_equal "provider-1", neutral.fetch(:"job.provider_id")
      assert_equal "critical", neutral.fetch(:"job.queue.name")
      assert_equal 10, neutral.fetch(:"job.priority")
      assert_equal 3, neutral.fetch(:"job.execution_count")
      assert_equal "2026-01-01T00:00:00Z", neutral.fetch(:"job.enqueued_at")
      assert_equal "2026-01-01T00:05:00Z", neutral.fetch(:"job.scheduled_at")
      assert_equal "ok", neutral.fetch(:"job.status")
      assert_equal(
        { "job.system": "active_job" },
        Julewire::ActiveJob::JobAttributes.call(Object.new)
      )
    end

    def test_job_attributes_handles_string_keyed_hashes
      attributes = Julewire::ActiveJob::JobAttributes.call(
        "class_name" => "StringKeyJob",
        "id" => "job-string",
        "queue_name" => "default"
      )

      neutral = attributes

      assert_equal "StringKeyJob", neutral.fetch(:"job.name")
      assert_equal "job-string", neutral.fetch(:"job.id")
      assert_equal "default", neutral.fetch(:"job.queue.name")
    end

    def test_event_subscriber_install_returns_nil_without_reporter
      Julewire::ActiveJob::Subscribers::Event.reset!

      with_overridden_singleton_method(Julewire::Core::Integration::Lifecycle, :require_optional, proc { |*| }) do
        assert_nil Julewire::ActiveJob::Subscribers::Event.install!(
          Julewire::ActiveJob::Configuration.new,
          event_reporter: Object.new
        )
      end
    ensure
      Julewire::ActiveJob::Subscribers::Event.reset!
    end

    def test_event_subscriber_install_rescues_missing_structured_event_subscriber
      Julewire::ActiveJob::Subscribers::Event.reset!
      reporter = FakeReporter.new
      required = []

      subscriber = with_overridden_singleton_method(
        Julewire::Core::Integration::Lifecycle,
        :require_optional,
        proc { |path| required << path }
      ) do
        Julewire::ActiveJob::Subscribers::Event.install!(
          Julewire::ActiveJob::Configuration.new,
          event_reporter: reporter
        )
      end

      assert_instance_of Julewire::ActiveJob::Subscribers::Event, subscriber
      assert_equal 1, reporter.subscriptions.length
      assert_equal [Julewire::ActiveJob::Subscribers::Event::STRUCTURED_EVENT_FILE], required
    ensure
      Julewire::ActiveJob::Subscribers::Event.reset!
    end
  end

  class TestActiveJobInternalSubscriberPaths < Minitest::Test
    cover Julewire::ActiveJob::Subscribers::Event
    cover Julewire::ActiveJob::JobAttributes
    def test_structured_event_subscriber_path_resolves_against_current_active_job
      path = Julewire::ActiveJob::Subscribers::Event::STRUCTURED_EVENT_FILE

      refute_nil Julewire::Core::Integration::Lifecycle.require_optional(path), "#{path} should resolve"
    end
  end
end
