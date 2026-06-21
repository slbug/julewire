# frozen_string_literal: true

require "support/active_job_test_support"

module Julewire
  class TestActiveJobEventSubscriber < Minitest::Test
    include ActiveJobTestSupport

    cover Julewire::ActiveJob::JobAttributes
    cover Julewire::ActiveJob::Subscribers::Event

    def test_event_subscriber_rejects_when_structured_events_are_disabled
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.structured_events = false
      subscriber = Julewire::ActiveJob::Subscribers::Event.new(configuration)

      refute subscriber.accept?(name: "active_job.perform")
    end

    def test_event_subscriber_install_resets_existing_subscription_when_disabled
      reporter = FakeReporter.new
      configuration = Julewire::ActiveJob::Configuration.new
      disabled_configuration = Julewire::ActiveJob::Configuration.new
      disabled_configuration.structured_events = false

      Julewire::ActiveJob::Subscribers::Event.reset!
      with_overridden_singleton_method(Julewire::Core::Integration::Lifecycle, :require_optional, proc { |*| }) do
        subscriber = Julewire::ActiveJob::Subscribers::Event.install!(configuration, event_reporter: reporter)

        assert_nil Julewire::ActiveJob::Subscribers::Event.install!(disabled_configuration, event_reporter: reporter)
        assert_equal [subscriber], reporter.unsubscriptions
      end
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

      assert subscriber.accept?(name: "other.event")
      subscriber.emit(
        name: "other.event",
        payload: "value",
        timestamp: Object.new,
        tags: "bad",
        context: "bad",
        source_location: { filepath: "app/jobs/import_job.rb", lineno: 42, label: "ImportJob#perform" }
      )

      record = records.fetch(0)

      assert_other_event_record(record)
      assert_equal({ value: "value" }, active_job_attributes(record))
      assert_source_location_attributes(record)
      refute record.key?(:tags)
      refute active_job_attributes(record).key?(:tags)
      assert_empty record.fetch(:context)
      assert_active_job_record_contract(record)
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

      subscriber.emit(
        name: "active_job.enqueued",
        payload: { exception_class: "ActiveJob::EnqueueError", exception_message: "boom" }
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
      subscriber = Julewire::ActiveJob::Subscribers::Event.new

      Julewire::ActiveJob::JobExecution.call(fake_job, configuration: Julewire::ActiveJob::Configuration.new) do
        subscriber.emit(
          name: "active_job.custom_continuation",
          payload: { step: "unknown", cursor: 1 }
        )
      end

      summary = records.find { it[:kind] == :summary }

      refute active_job_attributes(summary).key?(:continuation_last_step)
      refute active_job_attributes(summary).key?(:continuation_steps_started)
    end

    def test_event_subscriber_records_adapter_failures
      subscriber = Julewire::ActiveJob::Subscribers::Event.new
      bad_event = Object.new
      bad_event.define_singleton_method(:[]) { |_key| raise "bad event" }

      _health, integration = assert_julewire_integration_failure_contract(
        integration: :active_job,
        component: :event_subscriber,
        exercise: -> { subscriber.emit(bad_event) }
      )

      assert_equal :emit, integration.dig(:last_failure, :action)
      assert_equal "RuntimeError", integration.dig(:last_failure, :class)
    end

    def test_event_subscriber_contains_chaos_failures
      Julewire::Testing::Chaos.assert_emitter_chaos_contract(
        self,
        component: :active_job_event_subscriber,
        build: ->(_error) { Julewire::ActiveJob::Subscribers::Event.new },
        exercise: ->(subscriber, error) { subscriber.emit(raising_event(error)) }
      )
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

      subscriber = with_overridden_singleton_method(
        Julewire::Core::Integration::Lifecycle,
        :require_optional,
        proc { |*| }
      ) do
        Julewire::ActiveJob::Subscribers::Event.install!(
          Julewire::ActiveJob::Configuration.new,
          event_reporter: reporter
        )
      end

      assert_instance_of Julewire::ActiveJob::Subscribers::Event, subscriber
      assert_equal 1, reporter.subscriptions.length
    ensure
      Julewire::ActiveJob::Subscribers::Event.reset!
    end

    private

    def raising_event(error)
      Object.new.tap do |event|
        event.define_singleton_method(:[]) { |_key| raise error }
      end
    end
  end

  class TestActiveJobInternalSubscriberPaths < Minitest::Test
    def test_structured_event_subscriber_path_resolves_against_current_active_job
      path = Julewire::ActiveJob::Subscribers::Event::STRUCTURED_EVENT_FILE

      refute_nil Julewire::Core::Integration::Lifecycle.require_optional(path), "#{path} should resolve"
    end
  end
end
