# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestIntegrationHelpers < Minitest::Test
    cover "Julewire::Core::ContextStore#merged_execution_hash"
    cover Julewire::Core::Integration::Values
    cover "Julewire::Core::Integration::Values::Read.value"
    cover Julewire::Core::Integration::Settings
    cover Julewire::Core::Integration::Health
    cover Julewire::Core::Integration::Facade
    cover "Julewire::Core::Integration::IvarState*"
    cover "Julewire::Core::Integration::Scoped*"
    cover "Julewire::Core::Integration::SubscriberInstall*"
    cover "Julewire::Core::Integration::Subscription*"
    cover "Julewire::Core::Integration::Lifecycle.require_optional"
    cover "Julewire::Core::Runtime#record_integration_success"
    class DivmodFailure
      def divmod(_divisor)
        raise "bad timestamp"
      end
    end

    class UtcOnlyTimestamp
      def utc = self
    end

    class IsoOnlyTimestamp
      def iso8601(_precision) = "local"
    end

    class ZonedTimestamp
      def utc = UtcTimestamp.new

      def iso8601(_precision) = "local"
    end

    class UtcTimestamp
      def iso8601(_precision) = "utc"
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

    class BrokenIndexedPayload
      def [](_key)
        raise "index failed"
      end
    end

    class BrokenReader
      def id
        raise "read failed"
      end
    end

    class LyingIndexedPayload
      def method_missing(name, *_arguments)
        return "hidden-index" if name == :[]

        super
      end

      def respond_to_missing?(_name, _include_private = false) = false
    end

    class LyingReader
      def method_missing(name, *_arguments)
        return "hidden-reader" if name == :id

        super
      end

      def respond_to_missing?(_name, _include_private = false) = false
    end

    class BracketHash < Hash
      def [](key)
        "bracket:#{super.inspect}"
      end

      def fetch(key, *_arguments)
        "fetch:#{key.inspect}"
      end
    end

    class RejectingHash < Hash
      def [](key)
        raise "unexpected bracket read: #{key.inspect}"
      end

      def fetch(key, *_arguments)
        raise "unexpected fetch: #{key.inspect}"
      end
    end

    class SummaryScopeSpy
      attr_reader :calls

      def initialize
        @calls = []
      end

      def add_summary_attributes(fields, owned:)
        @calls << [:attributes, fields, owned]
      end
    end

    CurrentScopeSpy = Data.define(:current_scope)

    class IndexableSourceLocation
      def [](key)
        {
          filepath: "app/not_a_hash.rb",
          lineno: 99,
          label: "call"
        }.fetch(key)
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

      setting :enabled, default: true, predicate: true
      setting :limit, default: 1, validate: integer_limit(positive: true)
      setting :path, default: "ok", validate: :validate_path

      private

      def validate_path(value, name)
        raise ArgumentError, "#{name} cannot be empty" if value.empty?

        value
      end
    end

    def test_generated_setting_predicates_return_booleans
      settings = SettingsExample.new

      settings.enabled = Object.new

      assert_true settings.enabled?
      settings.enabled = nil

      assert_false settings.enabled?
    end

    def test_record_failure_records_integration_health
      health_facade = Julewire::Core::Integration::Health

      result = health_facade.record_failure(:web, RuntimeError.new("install failed"), component: :install)

      health = Julewire.health.fetch(:process_integrations).fetch(:web)

      assert_nil result
      assert_equal :degraded, health.fetch(:status)
      assert_equal 1, health.dig(:counts, :failures)
      assert_equal :install, health.dig(:last_failure, :component)
    end

    def test_record_success_defaults_to_process_integration_health
      health_facade = Julewire::Core::Integration::Health

      result = health_facade.record_success(:web)

      health = Julewire.health.fetch(:process_integrations).fetch(:web)

      assert_nil result
      assert_equal :ok, health.fetch(:status)
      assert_equal({ failures: 0 }, health.fetch(:counts))
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
      assert_true yielded
      assert_nil failure
      assert_equal :degraded, health.fetch(:status)
      assert_equal :subscribe, health.dig(:last_failure, :action)

      health_facade.with_failure_health(:web, component: :install, action: :subscribe) { :ok }

      assert_equal :ok, Julewire.health.dig(:process_integrations, :web, :status)
    end

    def test_summary_attribute_enrichment_rejects_non_hash_fields
      scope = SummaryScopeSpy.new
      store = CurrentScopeSpy.new(scope)

      error = with_overridden_singleton_method(Julewire::Core::ContextStore, :current, proc { store }) do
        assert_raises(TypeError) do
          Julewire::Core::Integration::Facade.add_summary_attributes(Object.new)
        end
      end

      assert_equal "owned data must be a Hash", error.message
      assert_empty scope.calls
    end

    def test_summary_attribute_enrichment_compacts_empty_fields
      scope = SummaryScopeSpy.new
      store = CurrentScopeSpy.new(scope)

      with_overridden_singleton_method(Julewire::Core::ContextStore, :current, proc { store }) do
        Julewire::Core::Integration::Facade.add_summary_attributes(http: { request: {} })
      end

      assert_empty scope.calls
    end

    def test_summary_attribute_enrichment_writes_owned_hashes
      scope = SummaryScopeSpy.new
      store = CurrentScopeSpy.new(scope)
      fields = RejectingHash[http: { status: 200 }]

      with_overridden_singleton_method(Julewire::Core::ContextStore, :current, proc { store }) do
        Julewire::Core::Integration::Facade.add_summary_attributes(fields)
      end

      assert_equal [[:attributes, fields, true]], scope.calls
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
      error = RuntimeError.new("audit failed")

      health.record_failure(error, component: :subscriber, action: :emit)
      health.record_success

      default_health = Julewire.health
      audit_health = audit.health

      assert_empty default_health.fetch(:integrations)
      assert_empty default_health.fetch(:process_integrations)
      assert_equal :ok, audit_health.dig(:integrations, :audit_adapter, :status)
      assert_equal 1, audit_health.dig(:integrations, :audit_adapter, :counts, :failures)
      assert_equal "RuntimeError", audit_health.dig(:integrations, :audit_adapter, :last_failure, :class)
      assert_equal :subscriber, audit_health.dig(:integrations, :audit_adapter, :last_failure, :component)
      assert_empty audit_health.fetch(:process_integrations)
      assert_equal :degraded, audit_health.fetch(:status)
    end

    def test_scoped_integration_health_can_be_constructed_without_runtime
      health = Julewire::Core::Integration::Scoped.new(:direct_adapter)

      assert_nil health.record_failure(RuntimeError.new("direct failed"), component: :subscriber)

      direct_health = Julewire.health.fetch(:process_integrations).fetch(:direct_adapter)

      assert_equal :degraded, direct_health.fetch(:status)
      assert_equal "RuntimeError", direct_health.dig(:last_failure, :class)
    end

    def test_runtime_scoped_failure_health_records_success_on_named_runtime
      audit = Julewire.runtime(:audit)
      health = Julewire::Core::Integration::Health.scoped(:audit_adapter, runtime: audit)
      health.record_failure(RuntimeError.new("audit failed"), component: :subscriber, action: :emit)

      assert_equal :ok, health.with_failure_health(component: :subscriber, action: :emit) { :ok }

      default_health = Julewire.health
      audit_health = audit.health

      assert_empty default_health.fetch(:integrations)
      assert_equal :ok, audit_health.dig(:integrations, :audit_adapter, :status)
    end

    def test_runtime_scoped_failure_health_records_failures_on_named_runtime
      audit = Julewire.runtime(:audit)
      health = Julewire::Core::Integration::Health.scoped(:audit_adapter, runtime: audit)

      result = health.with_failure_health(component: :subscriber, action: :emit, status: :failed) do
        raise "audit failed"
      end

      default_health = Julewire.health
      audit_health = audit.health
      failure = audit_health.dig(:integrations, :audit_adapter, :last_failure)

      assert_nil result
      assert_empty default_health.fetch(:integrations)
      assert_empty default_health.fetch(:process_integrations)
      assert_equal :degraded, audit_health.dig(:integrations, :audit_adapter, :status)
      assert_equal "RuntimeError", failure.fetch(:class)
      assert_equal :subscriber, failure.fetch(:component)
      assert_equal :emit, failure.fetch(:action)
      assert_equal :failed, failure.fetch(:status)
      assert_empty audit_health.fetch(:process_integrations)
    end

    def test_with_execution_opens_integration_execution_boundary
      records = capture_julewire_records do
        Julewire::Core::Integration::Facade.with_execution(
          type: :job,
          id: "job-1",
          fields: { job_class: "ReportJob" },
          attributes: { active_job: { job_id: "job-1" } },
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

    def test_with_execution_requires_block_for_integration_spi
      error = assert_raises(ArgumentError) do
        Julewire::Core::Integration::Facade.with_execution(type: :job)
      end

      assert_equal "block required", error.message
    end

    def test_emit_forwards_owned_keyword_input_to_integration_runtime
      runtime = Object.new
      calls = []
      runtime.define_singleton_method(:emit_integration) do |record, enforce_level:|
        calls << [record, enforce_level]
      end

      result = with_overridden_singleton_method(Julewire::Core::RuntimeLocator, :current, proc { runtime }) do
        Julewire::Core::Integration::Facade.emit(event: "integration.event")
        Julewire::Core::Integration::Facade.emit({ event: "integration.forced" }, enforce_level: false)
      end

      assert_nil result
      assert_equal [[{ event: "integration.event" }, true], [{ event: "integration.forced" }, false]], calls
    end

    def test_emit_without_positional_record_keeps_empty_keyword_input
      runtime = Object.new
      calls = []
      runtime.define_singleton_method(:emit_integration) do |record, enforce_level:|
        calls << [record, enforce_level]
      end

      with_overridden_singleton_method(Julewire::Core::RuntimeLocator, :current, proc { runtime }) do
        Julewire::Core::Integration::Facade.emit
      end

      assert_equal [[{}, true]], calls
    end

    def test_with_execution_forwards_owned_execution_to_current_runtime
      runtime = Object.new
      captured = {}
      runtime.define_singleton_method(:with_execution) do |type:, owned:, **options, &block|
        captured[:type] = type
        captured[:owned] = owned
        captured[:options] = options
        captured[:block] = block
        block.call(:integration_view)
      end

      write_sections = []
      result = with_overridden_singleton_method(
        Julewire::Core::Integration::Facade,
        :integration_write_section!,
        proc { |section| write_sections << section }
      ) do
        with_overridden_singleton_method(Julewire::Core::RuntimeLocator, :current, proc { runtime }) do
          Julewire::Core::Integration::Facade.with_execution(
            type: :job,
            id: "job-1",
            fields: { job_class: "ReportJob" },
            summary_event: "job.completed"
          ) { |view| [:returned, view] }
        end
      end

      assert_equal %i[returned integration_view], result
      assert_equal [:execution], write_sections
      assert_equal :job, captured.fetch(:type)
      assert_true captured.fetch(:owned)
      assert_equal(
        { id: "job-1", fields: { job_class: "ReportJob" }, summary_event: "job.completed" },
        captured.fetch(:options)
      )
      assert_instance_of Proc, captured.fetch(:block)
    end

    def test_with_execution_rejects_invalid_owned_options_before_runtime_delegation
      runtime = Object.new
      delegated = false
      runtime.define_singleton_method(:with_execution) { |**| delegated = true }
      previous_runtime = Julewire::Core::RuntimeLocator.current
      Julewire::Core::RuntimeLocator.current = runtime

      error = assert_raises(TypeError) do
        Julewire::Core::Integration::Facade.with_execution(
          type: :job,
          fields: { payload: { "job_id" => "job-1" } }
        ) { :unreachable }
      end

      assert_equal Julewire::Core::Fields::Internal::RECORD_STRING_KEY_ERROR, error.message
      assert_false delegated
    ensure
      Julewire::Core::RuntimeLocator.current = previous_runtime if defined?(previous_runtime)
    end

    def test_require_optional_contains_missing_load_errors
      assert_nil Julewire::Core::Integration::Lifecycle.require_optional("missing/julewire/optional")
      refute_nil Julewire::Core::Integration::Lifecycle.require_optional("time")
    end

    def test_timestamp_normalizes_common_adapter_values
      now = Time.utc(2026, 5, 30, 12, 0, 0, 123_456)

      assert_nil Julewire::Core::Integration::Values::Shape.timestamp(nil)
      assert_nil Julewire::Core::Integration::Values::Shape.timestamp(false)
      assert_equal "2026-05-30T12:00:00.123456000Z", Julewire::Core::Integration::Values::Shape.timestamp(now)
      assert_equal "raw", Julewire::Core::Integration::Values::Shape.timestamp("raw")
      assert_equal "1970-01-01T00:00:01.000000002Z", Julewire::Core::Integration::Values::Shape.timestamp(1_000_000_002)
      assert_equal "1970-01-01T00:00:03.000000005Z", Julewire::Core::Integration::Values::Shape.timestamp(3_000_000_005)
      assert_nil Julewire::Core::Integration::Values::Shape.timestamp(DivmodFailure.new)
    end

    def test_timestamp_requires_utc_and_iso8601_before_normalizing_temporal_ducks
      utc_only = UtcOnlyTimestamp.new
      iso_only = IsoOnlyTimestamp.new

      assert_same utc_only, Julewire::Core::Integration::Values::Shape.timestamp(utc_only)
      assert_same iso_only, Julewire::Core::Integration::Values::Shape.timestamp(iso_only)
      assert_equal "utc", Julewire::Core::Integration::Values::Shape.timestamp(ZonedTimestamp.new)
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

    def test_payload_hash_and_hash_or_empty_reuse_frozen_empty_hash
      values = Julewire::Core::Integration::Values::Shape

      nil_payload = values.payload_hash(nil)
      empty_payload = values.payload_hash({})
      empty_hash = values.hash_or_empty({})

      assert_same nil_payload, empty_payload
      assert_same nil_payload, empty_hash
      assert_predicate nil_payload, :frozen?
    end

    def test_hash_or_empty_accepts_hash_subclasses
      hash_class = Class.new(Hash)
      payload = hash_class.new.merge!("user_id" => 1)

      assert_equal({ user_id: 1 }, Julewire::Core::Integration::Values::Shape.hash_or_empty(payload))
    end

    def test_read_value_handles_hashes_objects_and_failures
      values = Julewire::Core::Integration::Values::Read
      object = Struct.new(:id).new("object-id")

      assert_equal "symbol-id", values.value({ id: "symbol-id", "id" => "string-id" }, :id)
      assert_equal "string-id", values.value({ "id" => "string-id" }, :id)
      assert_equal "object-id", values.value(object, :id)
      assert_equal "fallback", values.value(Object.new, :id, default: "fallback")
      assert_equal "fallback", values.value(BrokenReader.new, :id, default: "fallback")
    end

    def test_source_location_attributes_maps_supported_aliases
      attributes = Julewire::Core::Integration::Values::Shape.source_location_attributes(
        "filepath" => "app/jobs/report_job.rb",
        line: 42,
        "function" => "perform"
      )

      assert_equal(
        {
          "code.file.path": "app/jobs/report_job.rb",
          "code.line.number": 42,
          "code.function.name": "perform"
        },
        attributes
      )
    end

    def test_source_location_attributes_falls_back_and_compacts_blank_values
      attributes = Julewire::Core::Integration::Values::Shape.source_location_attributes(
        filepath: "",
        path: "",
        file: "app/controllers/reports_controller.rb",
        lineno: nil,
        line: 17,
        label: "",
        function: "show"
      )

      assert_equal(
        {
          "code.file.path": "app/controllers/reports_controller.rb",
          "code.line.number": 17,
          "code.function.name": "show"
        },
        attributes
      )
    end

    def test_source_location_attributes_accepts_hash_subclasses_and_alias_only_keys
      location = Class.new(Hash).new.merge!(
        path: "app/services/reports/export.rb",
        lineno: 8,
        label: "call"
      )

      assert_equal(
        {
          "code.file.path": "app/services/reports/export.rb",
          "code.line.number": 8,
          "code.function.name": "call"
        },
        Julewire::Core::Integration::Values::Shape.source_location_attributes(location)
      )
    end

    def test_source_location_attributes_rejects_non_hash_and_compacts_missing_fields
      values = Julewire::Core::Integration::Values::Shape

      assert_equal({}, values.source_location_attributes(nil))
      assert_equal({}, values.source_location_attributes("app/jobs/report_job.rb"))
      assert_equal({}, values.source_location_attributes(IndexableSourceLocation.new))
      assert_equal({ "code.file.path": "app/models/report.rb" },
                   values.source_location_attributes(file: "app/models/report.rb"))
    end

    def test_append_field_mutates_fields_and_skips_only_nil
      values = Julewire::Core::Integration::Values::Shape
      fields = {}

      assert_nil values.append_field(fields, :message, "saved")
      assert_nil values.append_field(fields, :missing, nil)
      assert_nil values.append_field(fields, :enabled, false)
      assert_nil values.append_field(fields, :empty_hash, {})
      assert_nil values.append_field(fields, :empty_array, [])

      assert_equal(
        {
          message: "saved",
          enabled: false,
          empty_hash: {},
          empty_array: []
        },
        fields
      )
    end

    def test_append_compact_field_skips_empty_containers_but_keeps_scalars
      values = Julewire::Core::Integration::Values::Shape
      fields = {}

      assert_nil values.append_compact_field(fields, :empty_hash, {})
      assert_nil values.append_compact_field(fields, :empty_array, [])
      assert_nil values.append_compact_field(fields, :empty_hash_subclass, Class.new(Hash).new)
      assert_nil values.append_compact_field(fields, :empty_array_subclass, Class.new(Array).new)
      assert_nil values.append_compact_field(fields, :nested_hash, { id: "job-1" })
      assert_nil values.append_compact_field(fields, :tags, ["critical"])
      assert_nil values.append_compact_field(fields, :empty_string, "")
      assert_nil values.append_compact_field(fields, :enabled, false)
      assert_nil values.append_compact_field(fields, :count, 0)

      assert_equal(
        {
          nested_hash: { id: "job-1" },
          tags: ["critical"],
          empty_string: "",
          enabled: false,
          count: 0
        },
        fields
      )
    end

    def test_summary_attribute_enrichment_only_updates_active_executions_with_fields
      records = capture_julewire_records do
        refute_predicate Julewire::Core::Integration::Facade, :summary_active?
        assert_nil Julewire::Core::Integration::Facade.add_summary_attributes(web: { ignored: true })
        assert_nil Julewire::Core::Integration::Facade.increment_summary_attribute(:web, :ignored)

        Julewire.with_execution(type: :request, id: "request-1", summary_event: "request.completed") do
          assert_predicate Julewire::Core::Integration::Facade, :summary_active?
          error = assert_raises(TypeError) do
            Julewire::Core::Integration::Facade.add_summary_attributes(nil)
          end
          assert_equal "owned data must be a Hash", error.message
          assert_nil Julewire::Core::Integration::Facade.add_summary_attributes(web: { empty: {} })
          assert_nil Julewire::Core::Integration::Facade.add_summary_attributes(web: { status: 200 })
          assert_nil Julewire::Core::Integration::Facade.increment_summary_attribute(:web, :queries_count)
          assert_nil Julewire::Core::Integration::Facade.increment_summary_attribute(:web, :queries_count, by: 2)
        end
      end

      summary = records.fetch(0)

      assert_equal 200, summary.dig(:attributes, :web, :status)
      assert_equal 3, summary.dig(:attributes, :web, :queries_count)
      assert_false summary.dig(:attributes, :web).key?(:empty)
    end

    def test_summary_attribute_enrichment_is_guarded_by_bag_capabilities
      with_overridden_singleton_method(
        Julewire::Core::Fields::Bags,
        :integration_write_sections,
        proc { [] }
      ) do
        error = assert_raises(ArgumentError) do
          Julewire::Core::Integration::Facade.add_summary_attributes(web: { status: 200 })
        end

        assert_equal "integration cannot write summary", error.message
      end
    end

    def test_summary_attribute_enrichment_accepts_hash_subclasses
      fields = Class.new(Hash).new.merge!(web: { status: 200 })
      records = capture_julewire_records do
        Julewire.with_execution(type: :request, id: "request-1", summary_event: "request.completed") do
          assert_nil Julewire::Core::Integration::Facade.add_summary_attributes(fields)
        end
      end

      assert_equal 200, records.fetch(0).dig(:attributes, :web, :status)
    end

    def test_summary_neutral_enrichment_merges_with_execution_neutral
      records = capture_julewire_records do
        assert_nil Julewire::Core::Integration::Facade.add_summary_neutral(worker: { ignored: true })

        with_request_summary_neutral do
          error = assert_raises(TypeError) do
            Julewire::Core::Integration::Facade.add_summary_neutral(nil)
          end
          assert_equal "owned data must be a Hash", error.message
          assert_nil Julewire::Core::Integration::Facade.add_summary_neutral(worker: { empty: {} })
          assert_nil Julewire::Core::Integration::Facade.add_summary_neutral(worker: { region: "eu" })
        end
      end

      summary = records.fetch(0)

      assert_equal "node-a", summary.dig(:neutral, :worker, :node)
      assert_equal "eu", summary.dig(:neutral, :worker, :region)
      assert_false summary.dig(:neutral, :worker).key?(:empty)
    end

    def test_summary_neutral_uses_execution_neutral_when_no_summary_neutral_exists
      records = capture_julewire_records do
        with_request_summary_neutral { :ok }
      end

      assert_equal({ worker: { node: "node-a" } }, records.fetch(0).fetch(:neutral))
    end

    def with_request_summary_neutral(&)
      Julewire::Core::Integration::Facade.with_execution(
        type: :request,
        id: "request-1",
        neutral: { worker: { node: "node-a" } },
        summary_event: "request.completed",
        &
      )
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
      payload_subclass = Class.new(Hash).new.merge!("id" => "subclass")

      assert_equal "job-1", values.nested_value(payload, :job, :id)
      assert_equal "fallback", values.nested_value(payload, :missing, :id, default: "fallback")
      assert_equal 2, values.path_value(payload, %i[job attempts])
      assert_equal "fallback", values.path_value(payload, %i[job missing], default: "fallback")
      assert_equal "fallback", values.path_value({ job: nil }, %i[job id], default: "fallback")
      assert_equal "fallback", values.nested_value({ job: nil }, :job, :nil?, default: "fallback")
      assert_equal "fallback", values.nested_value(nil, default: "fallback")
      assert_equal "fallback", values.path_value(Object.new, [:id], default: "fallback")
      assert_equal "fallback", values.path_value(BrokenIndexedPayload.new, [:id], default: "fallback")
      assert_equal "fallback", values.path_value(LyingIndexedPayload.new, [:id], default: "fallback")
      assert_equal "symbol", values.path_value({ token: "symbol" }, ["token"])
      assert_equal "symbol", values.path_value({ token: "symbol" }, :token)
      assert_equal "subclass", values.path_value(payload_subclass, [:id], default: "fallback")
      assert_equal "fallback", values.path_value({}, [Object.new], default: "fallback")
      assert_equal "trace-1", values.first_value(indexed, keys: %w[traceparent blank])
      assert_equal "job-1", values.first_value(payload.fetch("job"), keys: %w[missing id])
      assert_nil values.first_value(payload, keys: %w[blank missing])
    end

    def test_value_blankness_does_not_call_hidden_empty_methods
      value = Class.new do
        def method_missing(name, *)
          return true if name == :empty?

          super
        end

        def respond_to_missing?(_name, _include_private = false)
          false
        end
      end.new

      assert_false Julewire::Core::Integration::Values::Read.blank?(value)
    end

    def test_value_blankness_treats_nil_and_empty_values_as_blank
      values = Julewire::Core::Integration::Values::Read

      assert_true values.blank?(nil)
      assert_true values.blank?("")
      assert_true values.blank?([])
      assert_true values.blank?({})
    end

    def test_value_blankness_treats_broken_empty_as_nonblank
      value = Object.new
      def value.empty?
        raise "empty? failed"
      end

      assert_false Julewire::Core::Integration::Values::Read.blank?(value)
    end

    def test_hash_value_is_strict_to_hash_key_shapes
      key = Object.new
      def key.to_s = "id"
      def key.to_sym = :id

      payload = { "id" => "string", token: "symbol" }
      payload_subclass = Class.new(Hash).new.merge!("id" => "subclass")
      bracket_hash = BracketHash.new.merge!("id" => "string", token: "symbol")
      values = Julewire::Core::Integration::Values::Read

      assert_equal "string", values.hash_value(payload, :id)
      assert_equal "symbol", values.hash_value(payload, "token")
      assert_equal "fallback", values.hash_value(payload, key, default: "fallback")
      assert_equal "fallback", values.hash_value("not-a-hash", :id, default: "fallback")
      assert_equal "fallback", values.hash_value({}, :missing, default: "fallback")
      assert_equal "fallback", values.hash_value({}, "missing", default: "fallback")
      assert_equal "subclass", values.value(payload_subclass, :id, default: "fallback")
      assert_equal "fallback", values.value(Object.new, :id, default: "fallback")
      assert_equal "fallback", values.value(BrokenReader.new, :id, default: "fallback")
      assert_equal "fallback", values.value({}, :missing, default: "fallback")
      assert_equal "fallback", values.value(LyingReader.new, :id, default: "fallback")
      assert_equal "bracket:\"string\"", values.hash_value(bracket_hash, "id")
      assert_equal "bracket:\"string\"", values.hash_value(bracket_hash, :id)
      assert_equal "bracket:\"symbol\"", values.hash_value(bracket_hash, "token")
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
      assert_equal :value, state.store(owner, :value)
      assert_equal :value, state.fetch(owner)
      assert_equal :value, state.store(OpaqueInstallOwner.new, :value)
      assert_nil state.fetch(OpaqueInstallOwner.new)
      assert_equal :value, state.store(BrokenInstallOwner.new, :value)
      assert_nil state.fetch(BrokenInstallOwner.new)
    end

    def test_ivar_state_fetch_reads_existing_value_and_hides_owner_failures
      owner = Object.new
      state = Julewire::Core::Integration::IvarState.new(:@installed)

      owner.instance_variable_set(:@installed, :already_installed)

      assert_equal :already_installed, state.fetch(owner)
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

      error = assert_raises(ArgumentError) do
        Julewire::Core::Integration::Subscription.new(subscriber, unsubscribe: nil)
      end
      assert_equal "unsubscribe must respond to #call", error.message
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

    def test_subscriber_install_accepts_nil_unsubscribe
      subscriber = SubscriberInstallExample.install(:first, enabled: true) { -> {} }

      assert_same subscriber, SubscriberInstallExample.subscriber
      assert_nil SubscriberInstallExample.reset!
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

    def test_settings_integer_limit_validators_cover_non_negative_and_positive_modes
      klass = Class.new do
        include Julewire::Core::Integration::Settings

        setting :count, default: 0, validate: integer_limit
        setting :size, default: 1, validate: integer_limit(positive: true)
      end

      settings = klass.new

      settings.count = 0
      settings.size = 2

      assert_equal 0, settings.count
      assert_equal 2, settings.size

      count_error = assert_raises(ArgumentError) { settings.count = -1 }
      size_error = assert_raises(ArgumentError) { settings.size = 0 }

      assert_equal "count must be a non-negative Integer", count_error.message
      assert_equal "size must be a positive Integer", size_error.message
    end

    def test_settings_byte_limit_validator_shape_and_constant_resolution
      klass = Class.new do
        include Julewire::Core::Integration::Settings

        class << self
          def validator = byte_limit
        end
      end
      validator = klass.validator
      shadow = Module.new do
        class << self
          def validate_byte_limit!(*)
            raise "wrong validation constant"
          end
        end
      end

      with_temporary_constant(Julewire::Core::Integration::Settings::ClassMethods, :Validation, shadow) do
        refute_predicate validator, :lambda?
        assert_nil validator.call(nil, :limit)
        assert_equal 2, validator.call(2, :limit)
        error = assert_raises(ArgumentError) { validator.call(0, :limit) }

        assert_equal "limit must be nil or a positive Integer", error.message
      end
    end

    def test_settings_integer_limit_validator_shape_and_constant_resolution
      klass = Class.new do
        include Julewire::Core::Integration::Settings

        class << self
          def validator = integer_limit
        end
      end
      validator = klass.validator
      shadow = Module.new do
        class << self
          def validate_integer_limit!(*)
            raise "wrong validation constant"
          end
        end
      end

      with_temporary_constant(Julewire::Core::Integration::Settings::ClassMethods, :Validation, shadow) do
        refute_predicate validator, :lambda?
        assert_equal 2, validator.call(2, :count)
      end
    end

    def test_settings_initialize_defaults_predicates_and_defensive_copies
      klass = Class.new do
        include Julewire::Core::Integration::Settings

        setting :enabled, default: true, predicate: true
        setting :disabled, default: false, predicate: true
        setting :optional, predicate: true
        setting :truthy_object, predicate: true
        setting :nested, default: { tags: [] }
      end
      first = klass.new
      second = klass.new

      first.nested.fetch(:tags) << "api"
      first.truthy_object = Object.new

      assert_true first.enabled
      assert_predicate first, :enabled?
      refute_predicate first, :disabled?
      refute_predicate first, :optional?
      assert_true first.truthy_object?
      assert_equal({ tags: ["api"] }, first.nested)
      assert_equal({ tags: [] }, second.nested)
    end

    def test_settings_allow_nil_default_without_predicate_reader
      klass = Class.new do
        include Julewire::Core::Integration::Settings

        setting :optional
      end
      settings = klass.new

      assert_nil settings.optional
      refute_respond_to settings, :optional?

      settings.optional = "configured"

      assert_equal "configured", settings.optional
      assert_empty klass.settings_validators
    end

    def test_settings_block_defaults_override_static_defaults
      klass = Class.new do
        include Julewire::Core::Integration::Settings

        setting(:name, default: "static") { default_name }

        private

        def default_name
          "dynamic"
        end
      end

      assert_equal "dynamic", klass.new.name
    end

    def test_settings_support_all_validator_shapes
      klass = Class.new do
        include Julewire::Core::Integration::Settings

        setting :symbol_one, default: "low", validate: :normalize_symbol_one
        setting :symbol_two, default: "low", validate: :normalize_symbol_two
        setting :proc_one, default: "low", validate: lambda(&:upcase)
        setting :proc_two, default: "low", validate: proc { |value, name| "#{name}=#{value}" }
        setting :nil_result, default: "kept", validate: proc { |_value| }

        private

        def normalize_symbol_one(value)
          value.upcase
        end

        def normalize_symbol_two(value, name)
          "#{name}=#{value}"
        end
      end

      settings = klass.new

      assert_equal "LOW", settings.symbol_one
      assert_equal "symbol_two=low", settings.symbol_two
      assert_equal "LOW", settings.proc_one
      assert_equal "proc_two=low", settings.proc_two
      assert_equal "kept", settings.nil_result

      settings.symbol_one = "next"
      settings.symbol_two = "next"
      settings.proc_one = "next"
      settings.proc_two = "next"
      settings.nil_result = "next"

      assert_equal "NEXT", settings.symbol_one
      assert_equal "symbol_two=next", settings.symbol_two
      assert_equal "NEXT", settings.proc_one
      assert_equal "proc_two=next", settings.proc_two
      assert_equal "next", settings.nil_result
    end

    def test_settings_validate_revalidates_current_values_and_returns_self
      klass = Class.new do
        include Julewire::Core::Integration::Settings

        setting :name, default: "ok", validate: proc(&:upcase)
      end
      settings = klass.new
      settings.instance_variable_set(:@name, "raw")

      assert_same settings, settings.validate!
      assert_equal "RAW", settings.name
    end
  end
end
