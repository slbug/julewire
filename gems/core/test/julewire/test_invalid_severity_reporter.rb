# frozen_string_literal: true

require "test_helper"
require "stringio"

module Julewire
  class TestInvalidSeverityReporter < Minitest::Test
    cover Julewire::Core::Diagnostics::InvalidSeverityReporter
    cover "Julewire::Core::Processing::Pipeline#build_threshold"
    cover "Julewire::Core::Runtime#configure_transaction"
    cover "Julewire::Core::Runtime#initialize"
    cover "Julewire::Core::Runtime#reset_under_lock"
    def test_warn_once_emits_one_warning_with_value_class
      reporter = Julewire::Core::Diagnostics::InvalidSeverityReporter
      warnings = []

      reporter.reset!
      with_overridden_singleton_method(Warning, :warn, proc { |message| warnings << message }) do
        reporter.warn_once(value_class: "Object")
        reporter.warn_once(value_class: "String")
      end

      assert_equal ["julewire: unsupported record severity Object; using :info\n"], warnings
    ensure
      reporter&.reset!
    end

    def test_warn_once_can_warn_again_after_reset
      reporter = Julewire::Core::Diagnostics::InvalidSeverityReporter
      warnings = []

      reporter.reset!
      with_overridden_singleton_method(Warning, :warn, proc { |message| warnings << message }) do
        reporter.warn_once(value_class: "Object")
        reporter.reset!
        reporter.warn_once(value_class: "String")
      end

      assert_equal(
        [
          "julewire: unsupported record severity Object; using :info\n",
          "julewire: unsupported record severity String; using :info\n"
        ],
        warnings
      )
    ensure
      reporter&.reset!
    end

    def test_runtime_counter_records_count_and_metadata
      reporter = Julewire::Core::Diagnostics::InvalidSeverityReporter
      counter = reporter.counter
      metadata = []

      with_overridden_singleton_method(reporter, :warn_once, proc { |value| metadata << value }) do
        counter.call("debug-ish")
        counter.call(:bogus)
      end

      assert_equal({ count: 2 }, counter.health)
      assert_equal [{ value_class: "String" }, { value_class: "Symbol" }], metadata
    end

    def test_runtime_counter_counts_concurrent_calls_and_warns_once
      reporter = Julewire::Core::Diagnostics::InvalidSeverityReporter
      counter = reporter.counter
      warnings = Queue.new
      start = Queue.new
      threads = Array.new(16) do
        safe_thread do
          start.pop
          100.times { counter.call(:bogus) }
        end
      end

      reporter.reset!
      with_overridden_singleton_method(Warning, :warn, proc { |message| warnings << message }) do
        16.times { start << true }
        safe_thread_values(threads)
      end

      assert_equal({ count: 1_600 }, counter.health)
      assert_equal "julewire: unsupported record severity Symbol; using :info\n", safe_queue_pop(warnings)
      assert_raises(ThreadError) { warnings.pop(true) }
    ensure
      threads&.each { cleanup_thread(it) }
      reporter&.reset!
    end

    def test_runtime_counter_reset_clears_count
      reporter = Julewire::Core::Diagnostics::InvalidSeverityReporter
      counter = reporter.counter

      with_overridden_singleton_method(reporter, :warn_once, proc { |_metadata| }) do
        counter.call(:bogus)
      end
      counter.reset!

      assert_equal({ count: 0 }, counter.health)
    end

    def test_runtime_counter_contains_warning_failures
      reporter = Julewire::Core::Diagnostics::InvalidSeverityReporter
      counter = reporter.counter

      result = with_overridden_singleton_method(reporter, :warn_once, proc { |_metadata| raise "warning failed" }) do
        counter.call(:bogus)
      end

      assert_nil result
      assert_equal({ count: 1 }, counter.health)
    end

    def test_runtime_reset_clears_invalid_severity_count_and_allows_warning_again
      reporter = Julewire::Core::Diagnostics::InvalidSeverityReporter
      runtime = Julewire::Core::Runtime.new
      warnings = []

      reporter.reset!
      configure_runtime_output(runtime)
      with_overridden_singleton_method(Warning, :warn, proc { |message| warnings << message }) do
        runtime.emit(severity: Object.new, message: "first")

        assert_equal 1, runtime.health.dig(:counts, :invalid_record_severities)

        runtime.reset!

        assert_equal 0, runtime.health.dig(:counts, :invalid_record_severities)

        configure_runtime_output(runtime)
        runtime.emit(severity: Object.new, message: "second")
      end

      assert_equal 2, warnings.length
      assert_equal 1, runtime.health.dig(:counts, :invalid_record_severities)
    ensure
      reporter&.reset!
      runtime&.close
    end

    def test_metadata_records_named_value_class
      metadata = Julewire::Core::Diagnostics::InvalidSeverityReporter.metadata("debug-ish")

      assert_equal({ value_class: "String" }, metadata)
      assert_predicate metadata, :frozen?
    end

    def test_metadata_uses_anonymous_class_string
      value = Class.new.new
      metadata = Julewire::Core::Diagnostics::InvalidSeverityReporter.metadata(value)

      assert_equal({ value_class: value.class.to_s }, metadata)
      assert_predicate metadata, :frozen?
    end

    def test_metadata_falls_back_when_value_class_lookup_fails
      value = Object.new

      def value.class
        raise "class lookup failed"
      end

      metadata = Julewire::Core::Diagnostics::InvalidSeverityReporter.metadata(value)

      assert_equal({ value_class: "unknown" }, metadata)
      assert_predicate metadata, :frozen?
    end

    private

    def configure_runtime_output(runtime)
      runtime.configure { configure_destination(it, output: StringIO.new) }
    end
  end
end
