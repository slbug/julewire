# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestCoreNormalizeName < Minitest::Test
    cover "Julewire::Core.normalize_name"

    def test_accepts_strings_and_symbols
      symbol = :queue_name

      assert_equal :queue_name, Julewire::Core.normalize_name("queue_name")
      assert_same symbol, Julewire::Core.normalize_name(symbol)
    end

    def test_rejects_empty_values_with_named_message
      string_error = assert_raises(ArgumentError) { Julewire::Core.normalize_name("", name: "runtime") }
      symbol_error = assert_raises(ArgumentError) { Julewire::Core.normalize_name(:"", name: "runtime") }
      type_error = assert_raises(ArgumentError) { Julewire::Core.normalize_name(Object.new, name: "runtime") }

      assert_equal "runtime must not be empty", string_error.message
      assert_equal "runtime must not be empty", symbol_error.message
      assert_equal "runtime must be a String or Symbol", type_error.message
    end

    def test_uses_name_as_the_default_error_label
      string_error = assert_raises(ArgumentError) { Julewire::Core.normalize_name("") }
      symbol_error = assert_raises(ArgumentError) { Julewire::Core.normalize_name(:"") }
      type_error = assert_raises(ArgumentError) { Julewire::Core.normalize_name(Object.new) }

      assert_equal "name must not be empty", string_error.message
      assert_equal "name must not be empty", symbol_error.message
      assert_equal "name must be a String or Symbol", type_error.message
    end
  end

  class TestCore < Minitest::Test
    cover "Julewire::Core.sentinel"
    cover Julewire::Core::Sentinel
    cover Julewire::Core::FacadePrivateMethods
    cover "Julewire::Core::Runtime#carry"
    cover "Julewire::Core::Runtime#config"
    cover "Julewire::Core::Runtime#context"
    cover "Julewire::Core::Runtime#runtime_state"
    cover "Julewire::Core::Runtime#summary"
    cover "Julewire::Core::FacadeMethods#after_fork!"
    cover "Julewire::Core::FacadeMethods#attributes"
    cover "Julewire::Core::FacadeMethods#carry"
    cover "Julewire::Core::FacadeMethods#close"
    cover "Julewire::Core::FacadeMethods#config"
    cover "Julewire::Core::FacadeMethods#configure"
    cover "Julewire::Core::FacadeMethods#context"
    cover "Julewire::Core::FacadeMethods#current_execution"
    cover "Julewire::Core::FacadeMethods#debug"
    cover "Julewire::Core::FacadeMethods#dev!"
    cover "Julewire::Core::FacadeMethods#doctor"
    cover "Julewire::Core::FacadeMethods#emit"
    cover "Julewire::Core::FacadeMethods#error"
    cover "Julewire::Core::FacadeMethods#fatal"
    cover "Julewire::Core::FacadeMethods#fiber"
    cover "Julewire::Core::FacadeMethods#flush"
    cover "Julewire::Core::FacadeMethods#health"
    cover "Julewire::Core::FacadeMethods#info"
    cover "Julewire::Core::FacadeMethods#labels"
    cover "Julewire::Core::FacadeMethods#measure"
    cover "Julewire::Core::FacadeMethods#measure_start"
    cover "Julewire::Core::FacadeMethods#observe_self!"
    cover "Julewire::Core::FacadeMethods#punk!"
    cover "Julewire::Core::FacadeMethods#reset!"
    cover "Julewire::Core::FacadeMethods#runtime"
    cover "Julewire::Core::FacadeMethods#start_execution"
    cover "Julewire::Core::FacadeMethods#summary"
    cover "Julewire::Core::FacadeMethods#tail"
    cover "Julewire::Core::FacadeMethods#thread"
    cover "Julewire::Core::FacadeMethods#unknown"
    cover "Julewire::Core::FacadeMethods#warn"
    cover "Julewire::Core::FacadeMethods#with_execution"
    def self.emit_severity_messages
      %i[debug info warn error fatal].each { |severity| Julewire.public_send(severity, "#{severity} message") }
    end

    def test_zeitwerk_eager_loads_core_tree
      Zeitwerk::Loader.eager_load_all

      assert_true Julewire::Core.const_defined?(:VERSION)
    end

    def test_core_singleton_methods_are_internal
      refute_respond_to Julewire::Core, :configure
      assert_respond_to Julewire, :configure
      assert_respond_to Julewire, :runtime
      assert_respond_to Julewire, :flush
      assert_respond_to Julewire, :close
      assert_true(%i[health after_fork!].all? { Julewire.respond_to?(it) })
      refute_respond_to Julewire, :reopen
      refute_respond_to Julewire, :install_at_exit_close
      refute_respond_to Julewire::Core, :loader
      refute_respond_to Julewire, :pipeline
      refute_respond_to Julewire, :pipeline=
    end

    def test_named_runtimes_have_independent_pipelines
      default_output = StringIO.new
      audit_output = StringIO.new

      Julewire.configure { configure_destination(it, output: default_output) }
      Julewire.runtime(:audit).configure { configure_destination(it, output: audit_output) }

      Julewire.emit(message: "default")
      Julewire.runtime(:audit).emit(message: "audit")

      assert_includes default_output.string, "default"
      refute_includes default_output.string, "audit"
      assert_includes audit_output.string, "audit"
      refute_includes audit_output.string, "default"
    end

    def test_named_runtime_fields_only_emit_does_not_invent_empty_message
      audit_output = StringIO.new
      Julewire.runtime(:audit).configure { configure_destination(it, output: audit_output) }

      Julewire.runtime(:audit).emit(event: "audit.event", payload: { count: 1 })

      record = JSON.parse(audit_output.string)

      assert_equal "audit.event", record.fetch("event")
      assert_equal 1, record.dig("payload", "count")
      assert_false record.key?("message")
    end

    def test_named_runtime_is_memoized
      assert_same Julewire.runtime(:audit), Julewire.runtime("audit")
      assert_same Julewire::Core::RuntimeLocator.current, Julewire.runtime
      assert_same Julewire::Core::RuntimeLocator.current, Julewire.runtime(:default)
    end

    def test_named_facade_helpers_route_to_named_runtime
      Julewire.runtime(:audit).configure { |config| config.level = :error }
      tail = Julewire.tail(:audit, capacity: 2)

      Julewire.runtime(:audit).emit(message: "audit", event: "audit.event", severity: :error)
      Julewire.emit(message: "default", event: "default.event")

      assert_equal :error, Julewire.doctor(:audit).dig(:runtime, :level)
      assert_equal(["audit.event"], tail.records.map { it.fetch("event") })
    end

    def test_facade_delegates_labels_and_after_fork_to_runtime
      labels = Object.new
      runtime = Object.new
      runtime.define_singleton_method(:labels) { labels }
      runtime.define_singleton_method(:after_fork!) { :forked }
      facade = facade_with_runtime(runtime)

      assert_same labels, facade.labels
      assert_equal :forked, facade.after_fork!
    end

    def test_tail_facade_uses_default_and_named_runtime_arguments
      runtime_names = []
      attached_runtimes = []
      attached_options = []
      facade = Object.new
      facade.extend Julewire::Core::FacadeMethods
      facade.define_singleton_method(:runtime) do |name = :default|
        runtime_names << name
        :runtime
      end

      with_overridden_singleton_method(Julewire::Core::Diagnostics::Tail, :attach!, proc { |runtime, **options|
        attached_runtimes << runtime
        attached_options << options
        :tail
      }) do
        assert_equal :tail, facade.tail(capacity: 2)
        assert_equal :tail, facade.tail(:audit, capacity: 2)
      end

      assert_equal %i[runtime runtime], attached_runtimes
      assert_equal [{ capacity: 2 }, { capacity: 2 }], attached_options
      assert_equal %i[default audit], runtime_names
    end

    def test_named_sentinels_are_frozen_and_readable
      sentinel = Julewire::Core.sentinel(:example)

      assert_predicate sentinel, :frozen?
      assert_equal :example, sentinel.name
      assert_equal "#<Julewire::Core::Sentinel example>", sentinel.inspect
      assert_equal "#<Julewire::Core::Sentinel example>", sentinel.to_s
    end

    def test_named_sentinels_reject_empty_names_with_sentinel_wording
      error = assert_raises(ArgumentError) { Julewire::Core.sentinel("") }

      assert_equal "sentinel must not be empty", error.message
    end

    def test_public_extension_aliases_point_to_core_contract_classes
      assert_same Julewire::Core::Records::Record, Julewire::Record
      assert_same Julewire::Core::Records::Draft, Julewire::RecordDraft
      assert_same Julewire::Core::Records::ConsoleFormatter, Julewire::ConsoleFormatter
      assert_same Julewire::Core::Records::Formatter, Julewire::RecordFormatter
      assert_same Julewire::Core::Serialization::JsonEncoder, Julewire::JsonEncoder
      assert_same Julewire::Core::Serialization::TextEncoder, Julewire::TextEncoder
      assert_same Julewire::Core::Serialization::Serializer, Julewire::Serializer
      assert_same Julewire::Core::Processing::Match, Julewire::Match
      assert_false Julewire.const_defined?(:CLI, false)
      assert_false Julewire.const_defined?(:Destination, false)
      assert_false Julewire.const_defined?(:MetaObserver, false)
      assert_false Julewire.const_defined?(:Severity, false)
    end

    def test_capture_julewire_records_collects_normalized_records
      records = capture_julewire_records do
        Julewire.emit(message: "hello", payload: { count: 1 })
      end

      assert_equal "hello", records.first[:message]
      assert_equal 1, records.first.dig(:payload, :count)
    end

    def test_emit_with_fields_only_does_not_synthesize_empty_message
      records = capture_julewire_records do
        Julewire.emit(event: "fields.only", payload: { count: 1 })
      end

      record = records.fetch(0)

      assert_equal "fields.only", record.fetch(:event)
      assert_nil record.fetch(:message)
      assert_equal 1, record.dig(:payload, :count)
    end

    def test_severity_helpers_without_record_emit_severity_only
      records = capture_julewire_records do
        %i[debug info warn error fatal].each { Julewire.public_send(it) }
      end

      assert_equal(%i[debug info warn error fatal], records.map { it.fetch(:severity) })
      assert_true(records.all? { it.fetch(:message).nil? })
    end

    def test_severity_helpers_with_scalar_records_preserve_message_and_severity
      records = capture_julewire_records do
        self.class.emit_severity_messages
      end

      assert_equal(%i[debug info warn error fatal], records.map { it.fetch(:severity) })
      assert_equal(
        ["debug message", "info message", "warn message", "error message", "fatal message"],
        records.map { it.fetch(:message) }
      )
    end

    def test_severity_helpers_forward_lazy_blocks
      records = capture_julewire_records do
        %i[debug info warn error fatal].each do |severity|
          Julewire.public_send(severity) { { message: "lazy #{severity}", payload: { source: severity } } }
        end
      end

      assert_equal(%i[debug info warn error fatal], records.map { it.fetch(:severity) })
      assert_equal(
        ["lazy debug", "lazy info", "lazy warn", "lazy error", "lazy fatal"],
        records.map { it.fetch(:message) }
      )
      assert_equal(%i[debug info warn error fatal], records.map { it.dig(:payload, :source) })
    end

    def test_severity_helpers_do_not_report_invalid_severities
      Julewire.configure { configure_destination(it, output: StringIO.new) }
      before = Julewire.health.dig(:counts, :invalid_record_severities)

      self.class.emit_severity_messages

      assert_equal before, Julewire.health.dig(:counts, :invalid_record_severities)
    end

    def test_start_execution_forwards_execution_fields
      handle = Julewire.start_execution(
        type: :request,
        fields: { request_id: "req-1" },
        emit_summary: false
      )

      assert_equal "req-1", handle.snapshot.execution_hash.fetch(:request_id)
    ensure
      handle&.finish
    end

    def test_punk_without_chaos_does_not_construct_chaos_output
      output = StringIO.new

      with_overridden_singleton_method(
        Julewire::Core::Destinations::ChaosOutput,
        :new,
        proc { raise "chaos output should not be built" }
      ) do
        Julewire.punk!(output: output, chaos: false)
      end

      Julewire.info("punk")

      assert_includes output.string, "punk"
    end

    def test_punk_banner_writes_default_banner_when_requested
      output = StringIO.new

      Julewire.punk!(output: output, chaos: false, banner: true)

      assert_equal "!!JULEWIRE PUNK!! chaos containment armed\n", output.string.lines.first
    end

    def test_punk_true_chaos_uses_default_chaos_options
      output = StringIO.new

      Julewire.punk!(output: output, chaos: true)

      health = Julewire.health.dig(:pipeline, :destinations, :default)

      assert_equal :ok, health.fetch(:status)
    end

    def test_punk_chaos_accepts_hash_subclass_options
      chaos_options = Class.new(Hash).new.merge!(rate: 2)

      error = assert_raises(ArgumentError) do
        Julewire.punk!(output: StringIO.new, chaos: chaos_options, banner: false)
      end

      assert_equal "chaos rate must be a finite Numeric between 0 and 1", error.message
    end

    def test_tail_facade_uses_core_tail_not_public_alias
      poison = Module.new do
        class << self
          def attach!(*)
            raise "public Tail alias should not be used"
          end
        end
      end
      original = Julewire.const_get(:Tail, false)
      Julewire.__send__(:remove_const, :Tail)
      Julewire.const_set(:Tail, poison)

      tail = Julewire.tail(capacity: 1)

      assert_instance_of Julewire::Core::Diagnostics::Tail, tail
    ensure
      Julewire.__send__(:remove_const, :Tail) if Julewire.const_defined?(:Tail, false)
      Julewire.const_set(:Tail, original) if original
    end

    def test_context_add_is_included_on_point_logs_and_summary_logs
      output = StringIO.new
      Julewire.configure do |config|
        configure_destination(config, output: output)
      end

      Julewire.with_execution(type: :operation, fields: { operation_id: "op-1" }) do
        Julewire.context.add(tenant_id: "tenant-1")
        Julewire.summary.add(plan: "pro")
        Julewire.emit(message: "hello", payload: { token: "secret" })
      end

      point = JSON.parse(output.string.lines.first)

      expected_point = %w[hello tenant-1 op-1 secret]
      actual_point = [
        point["message"], point.dig("context", "tenant_id"),
        point.dig("execution", "operation_id"), point.dig("payload", "token")
      ]

      assert_equal expected_point, actual_point

      summary = JSON.parse(output.string.lines.last)

      actual_summary = [summary["kind"], summary.dig("context", "tenant_id"), summary.dig("payload", "plan")]

      assert_equal %w[summary tenant-1 pro], actual_summary
      assert_in_delta 0, summary.dig("metrics", "duration_ms"), 1000
    end

    def test_context_with_cleans_up_after_the_block
      Julewire.context.add(account_id: "acct-1")

      inside = nil
      Julewire.context.with(order_id: "order-1") do
        inside = Julewire.context.to_h
      end
      outside = Julewire.context.to_h

      assert_equal "acct-1", inside[:account_id]
      assert_equal "order-1", inside[:order_id]
      assert_equal({ account_id: "acct-1" }, outside)
    end

    def test_concurrent_configure_calls_are_serialized
      ready = Queue.new
      start = Queue.new
      outputs = Array.new(2) { StringIO.new }

      threads = outputs.each_with_index.map do |output, index|
        safe_thread do
          ready << true
          start.pop
          Julewire.configure do |config|
            configure_destination(config, output: output)
            config.labels.add(worker: index)
          end
        end
      end

      2.times { safe_queue_pop(ready) }
      2.times { start << true }
      safe_thread_values(threads)

      Julewire.emit(message: "configured")

      written_outputs = outputs.select { it.string.include?("configured") }

      assert_equal 1, written_outputs.length
    end

    def test_summary_requires_an_execution_scope
      refute_predicate Julewire.summary, :active?

      error = assert_raises(Julewire::Core::Execution::NoCurrentError) do
        Julewire.summary.add(total: 1)
      end

      assert_match "current execution", error.message
    end

    def test_health_reports_runtime_generation
      before = Julewire.health

      Julewire.configure { configure_destination(it, output: StringIO.new) }

      after = Julewire.health

      assert_operator after.fetch(:generation), :>, before.fetch(:generation)
    end

    def test_execution_scope_finishes_with_error_on_exception
      records = capture_julewire_records do
        assert_raises(RuntimeError) do
          Julewire.with_execution(type: :active_job) do
            raise "boom"
          end
        end
      end

      summary = records.detect { it[:kind] == :summary }

      assert_equal :error, summary[:severity]
      assert_equal "RuntimeError", summary.dig(:error, :class)
    end

    def test_propagation_envelope_excludes_summary_data
      envelope = capture_propagation(
        type: :active_job,
        execution: { trace_id: "trace-1", correlation_id: "cor-1" },
        context: { tenant_id: "tenant-1" },
        carry: { http: { request_headers: { traceparent: "trace-1" } } },
        summary: { response_plan: "pro" }
      )

      assert_equal "tenant-1", envelope.dig(:context, "tenant_id")
      assert_equal "trace-1", envelope.dig(:carry, "http", "request_headers", "traceparent")
      assert_equal "trace-1", envelope.dig(:execution, "trace_id")
      refute_includes envelope.fetch(:context), "response_plan"
    end

    def test_json_encoder_serializes_guarded_formatter_values
      cyclic = {}
      cyclic[:self] = cyclic

      record = JSON.parse(
        Julewire::Core::Serialization::JsonEncoder.new.call(
          Julewire::Core::Records::Formatter.new.call(
            build_record(
              { timestamp: Time.utc(2026, 1, 1), payload: { cyclic: cyclic, symbol: :value } },
              context: {},
              scope: nil
            )
          )
        )
      )

      assert_equal "2026-01-01T00:00:00.000000000Z", record.fetch("timestamp")
      assert_equal "[Circular]", record.dig("payload", "cyclic", "self")
      assert_equal "value", record.dig("payload", "symbol")
    end

    private

    def facade_with_runtime(runtime)
      Object.new.tap do |facade|
        facade.extend Julewire::Core::FacadeMethods
        facade.define_singleton_method(:runtime) { runtime }
      end
    end
  end
end
