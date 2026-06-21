# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestIntegrationHelpers < Minitest::Test
    class DivmodFailure
      def divmod(_divisor)
        raise "bad timestamp"
      end
    end

    class BrokenInstallOwner
      def respond_to_missing?(name, _include_private)
        %i[instance_variable_get instance_variable_set].include?(name)
      end

      def instance_variable_get(_name)
        raise "fetch failed"
      end

      def instance_variable_set(_name, _value)
        raise "store failed"
      end
    end

    class OpaqueInstallOwner
      def respond_to?(_name, _include_private: false)
        false
      end
    end

    class IndexedPayload
      def initialize(values)
        @values = values
      end

      def [](key)
        @values.fetch(key)
      end
    end

    class MutableSubscriber
      attr_accessor :configuration

      def initialize(configuration)
        @configuration = configuration
      end
    end

    class SubscriberInstallExample
      extend Julewire::Core::Integration::SubscriberInstall

      attr_accessor :configuration

      def initialize(configuration)
        @configuration = configuration
      end

      class << self
        def install(configuration, enabled:, &)
          install_subscriber(configuration, enabled: enabled, &)
        end
      end
    end

    class SettingsExample
      include Julewire::Core::Integration::Settings

      setting :limit, default: 1, validate: integer_limit(positive: true)
      setting :path, default: "ok", validate: :validate_path

      private

      def validate_path(value, name)
        raise ArgumentError, "#{name} cannot be empty" if value.empty?

        value
      end
    end

    def test_record_failure_records_integration_health
      health_facade = Julewire::Core::Integration::Health

      health_facade.record_failure(:web, RuntimeError.new("install failed"), component: :install)

      health = Julewire.health.fetch(:process_integrations).fetch(:web)

      assert_equal :degraded, health.fetch(:status)
      assert_equal 1, health.dig(:counts, :failures)
      assert_equal :install, health.dig(:last_failure, :component)
    end

    def test_with_failure_health_contains_adapter_errors
      health_facade = Julewire::Core::Integration::Health
      yielded = false
      success = health_facade.with_failure_health(:web, component: :install, action: :subscribe) do
        yielded = true
        :ok
      end

      failure = health_facade.with_failure_health(:web, component: :install, action: :subscribe) do
        raise "subscribe failed"
      end

      health = Julewire.health.fetch(:process_integrations).fetch(:web)

      assert_equal :ok, success
      assert yielded
      assert_nil failure
      assert_equal :degraded, health.fetch(:status)
      assert_equal :subscribe, health.dig(:last_failure, :action)

      health_facade.with_failure_health(:web, component: :install, action: :subscribe) { :ok }

      assert_equal :ok, Julewire.health.dig(:process_integrations, :web, :status)
    end

    def test_scoped_integration_health_helper_forwards_metadata
      health = Julewire::Core::Integration::Health.scoped(:active_job)

      assert_equal :ok, health.with_failure_health(component: :events, action: :emit) { :ok }
      assert_nil health.with_failure_health(component: :events, action: :emit) { raise "failed" }
      health.record_success

      active_job_health = Julewire.health.fetch(:process_integrations).fetch(:active_job)

      assert_equal :ok, active_job_health.fetch(:status)
      assert_equal 1, active_job_health.dig(:counts, :failures)
      assert_equal :emit, active_job_health.dig(:last_failure, :action)
    end

    def test_runtime_scoped_integration_health_is_runtime_local
      audit = Julewire.runtime(:audit)
      health = Julewire::Core::Integration::Health.scoped(:audit_adapter, runtime: audit)

      health.record_failure(RuntimeError.new("audit failed"), component: :subscriber, action: :emit)

      default_health = Julewire.health
      audit_health = audit.health

      assert_empty default_health.fetch(:integrations)
      assert_empty default_health.fetch(:process_integrations)
      assert_equal :degraded, audit_health.dig(:integrations, :audit_adapter, :status)
      assert_equal :subscriber, audit_health.dig(:integrations, :audit_adapter, :last_failure, :component)
      assert_empty audit_health.fetch(:process_integrations)
      assert_equal :degraded, audit_health.fetch(:status)
    end

    def test_with_execution_opens_integration_execution_boundary
      records = capture_julewire_records do
        Julewire::Core::Integration::Facade.with_execution(
          type: :job,
          id: "job-1",
          fields: { job_class: "ReportJob" },
          attributes: { "active_job" => { "job_id" => "job-1" } },
          inherit_attributes: false,
          summary_event: "job.completed"
        ) { :ok }
      end

      summary = records.fetch(0)

      assert_equal "job.completed", summary.fetch(:event)
      assert_equal "job-1", summary.dig(:execution, :id)
      assert_equal "ReportJob", summary.dig(:execution, :job_class)
      assert_equal "job-1", summary.dig(:attributes, :active_job, :job_id)
    end

    def test_require_optional_contains_missing_load_errors
      assert_nil Julewire::Core::Integration::Lifecycle.require_optional("missing/julewire/optional")
      refute_nil Julewire::Core::Integration::Lifecycle.require_optional("time")
    end

    def test_timestamp_normalizes_common_adapter_values
      now = Time.utc(2026, 5, 30, 12, 0, 0, 123_456)

      assert_nil Julewire::Core::Integration::Values::Shape.timestamp(nil)
      assert_equal "2026-05-30T12:00:00.123456000Z", Julewire::Core::Integration::Values::Shape.timestamp(now)
      assert_equal "raw", Julewire::Core::Integration::Values::Shape.timestamp("raw")
      assert_equal "1970-01-01T00:00:01.000000002Z", Julewire::Core::Integration::Values::Shape.timestamp(1_000_000_002)
      assert_nil Julewire::Core::Integration::Values::Shape.timestamp(DivmodFailure.new)
    end

    def test_payload_hash_and_hash_or_empty_normalize_adapter_payloads
      assert_equal({}, Julewire::Core::Integration::Values::Shape.payload_hash(nil))
      assert_equal(
        { account_id: "acct-1" },
        Julewire::Core::Integration::Values::Shape.payload_hash("account_id" => "acct-1")
      )
      assert_equal({ Julewire::Core::Fields::FieldSet::VALUE_KEY => "raw" }, Julewire::Core::Integration::Values::Shape.payload_hash("raw"))

      assert_equal({ user_id: 1 }, Julewire::Core::Integration::Values::Shape.hash_or_empty("user_id" => 1))
      assert_equal({}, Julewire::Core::Integration::Values::Shape.hash_or_empty("raw"))
    end

    def test_summary_attribute_enrichment_only_updates_active_executions_with_fields
      records = capture_julewire_records do
        refute_predicate Julewire::Core::Integration::Facade, :summary_active?
        assert_nil Julewire::Core::Integration::Facade.add_summary_attributes(web: { ignored: true })
        assert_nil Julewire::Core::Integration::Facade.increment_summary_attribute(:web, :ignored)

        Julewire.with_execution(type: :request, id: "request-1", summary_event: "request.completed") do
          assert_predicate Julewire::Core::Integration::Facade, :summary_active?
          assert_nil Julewire::Core::Integration::Facade.add_summary_attributes(nil)
          assert_nil Julewire::Core::Integration::Facade.add_summary_attributes(web: { empty: {} })
          assert_nil Julewire::Core::Integration::Facade.add_summary_attributes(web: { status: 200 })
          assert_nil Julewire::Core::Integration::Facade.increment_summary_attribute(:web, :queries_count)
        end
      end

      summary = records.fetch(0)

      assert_equal 200, summary.dig(:attributes, :web, :status)
      assert_equal 1, summary.dig(:attributes, :web, :queries_count)
      refute summary.dig(:attributes, :web).key?(:empty)
    end

    def test_value_helpers_read_hashes_objects_and_indexed_payloads_safely
      values = Julewire::Core::Integration::Values::Read
      payload = {
        "job" => {
          "id" => "job-1",
          attempts: 2
        },
        "blank" => ""
      }
      indexed = IndexedPayload.new("traceparent" => "trace-1")

      assert_equal "job-1", values.nested_value(payload, :job, :id)
      assert_equal "fallback", values.nested_value(payload, :missing, :id, default: "fallback")
      assert_equal 2, values.path_value(payload, %i[job attempts])
      assert_equal "fallback", values.path_value(payload, %i[job missing], default: "fallback")
      assert_equal "fallback", values.path_value({ job: nil }, %i[job id], default: "fallback")
      assert_equal "fallback", values.path_value(Object.new, [:id], default: "fallback")
      assert_equal "symbol", values.path_value({ token: "symbol" }, ["token"])
      assert_equal "fallback", values.path_value({}, [Object.new], default: "fallback")
      assert_equal "trace-1", values.first_value(indexed, keys: %w[traceparent blank])
      assert_equal "job-1", values.first_value(payload.fetch("job"), keys: %w[missing id])
      assert_nil values.first_value(payload, keys: %w[blank missing])
    end

    def test_hash_value_is_strict_to_hash_key_shapes
      key = Object.new
      def key.to_s = "id"
      def key.to_sym = :id

      payload = { "id" => "string", token: "symbol" }

      assert_equal "string", Julewire::Core::Integration::Values::Read.hash_value(payload, :id)
      assert_equal "symbol", Julewire::Core::Integration::Values::Read.hash_value(payload, "token")
      assert_equal "fallback", Julewire::Core::Integration::Values::Read.hash_value(payload, key, default: "fallback")
    end

    def test_first_value_ignores_hash_defaults_for_missing_keys
      payload = Hash.new(0)
      payload[:id] = "job-1"

      assert_equal "job-1", Julewire::Core::Integration::Values::Read.first_value(payload, keys: %i[missing id])
      refute_includes payload, :missing
    end

    def test_first_value_does_not_trigger_hash_default_proc
      payload = Hash.new do |hash, key|
        hash[key] = "generated-#{key}"
      end
      payload[:id] = "job-1"

      assert_equal "job-1", Julewire::Core::Integration::Values::Read.first_value(payload, keys: %i[missing id])
      refute_includes payload, :missing
    end

    def test_ivar_state_handles_idempotent_owner_markers
      owner = Object.new
      state = Julewire::Core::Integration::IvarState.new(:@installed)

      first = state.fetch_or_store(owner) { :installed }
      second = state.fetch_or_store(owner) { :reinstalled }

      assert_equal :installed, first
      assert_equal :installed, second
      assert_equal :installed, state.fetch(owner)
      assert_equal :value, state.store(OpaqueInstallOwner.new, :value)
      assert_nil state.fetch(OpaqueInstallOwner.new)
      assert_equal :value, state.store(BrokenInstallOwner.new, :value)
      assert_nil state.fetch(BrokenInstallOwner.new)
    end

    def test_subscription_updates_and_resets_optional_subscriptions
      calls = []
      subscriber = MutableSubscriber.new(:first)
      subscription = Julewire::Core::Integration::Subscription.new(subscriber, unsubscribe: lambda {
        calls << :unsubscribe
      })

      assert_same subscriber, subscription.update(:next)
      assert_equal :next, subscriber.configuration
      assert_nil subscription.reset
      assert_equal [:unsubscribe], calls

      assert_nil Julewire::Core::Integration::Subscription.new(subscriber).reset
      assert_nil Julewire::Core::Integration::Subscription.new(
        subscriber,
        unsubscribe: -> { raise "unsubscribe failed" }
      ).reset
    end

    def test_subscriber_install_installs_updates_and_resets_subscriber_state
      calls = []

      first = SubscriberInstallExample.install(:first, enabled: true) do |subscriber|
        calls << [:subscribe, subscriber.configuration]
        -> { calls << [:unsubscribe, subscriber.configuration] }
      end
      second = SubscriberInstallExample.install(:second, enabled: true) do |_subscriber|
        calls << [:resubscribe]
      end

      assert_same first, second
      assert_same first, SubscriberInstallExample.subscriber
      assert_predicate SubscriberInstallExample, :installed?
      assert_equal :second, first.configuration
      assert_equal [%i[subscribe first]], calls

      assert_nil SubscriberInstallExample.install(:ignored, enabled: false)
      refute_predicate SubscriberInstallExample, :installed?
      assert_nil SubscriberInstallExample.subscriber
      assert_equal [%i[subscribe first], %i[unsubscribe second]], calls
      assert_nil SubscriberInstallExample.install(:ignored, enabled: false)
    ensure
      SubscriberInstallExample.reset!
    end

    def test_settings_validate_assignment_values
      settings = SettingsExample.new

      settings.limit = 2
      settings.path = "custom"

      assert_equal 2, settings.limit
      assert_equal "custom", settings.path
      assert_raises(ArgumentError) { settings.limit = 0 }
      assert_raises(ArgumentError) { settings.path = "" }
    end
  end
end
