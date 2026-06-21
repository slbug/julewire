# frozen_string_literal: true

require "test_helper"
require "julewire/core/testing"

module Julewire
  class TestTestingHelpers < Minitest::Test
    STABLE_FACADE_METHODS = %i[
      after_fork!
      attributes
      carry
      close
      config
      configure
      context
      current_execution
      current_execution?
      debug
      dev!
      doctor
      emit
      error
      fatal
      fiber
      flush
      health
      info
      labels
      measure
      measure_start
      observe_self!
      punk!
      reset!
      runtime
      start_execution
      summary
      tail
      thread
      unknown
      warn
      with_execution
    ].sort.freeze
    CHAOS_HELPERS = %i[
      assert_contained
      assert_core_runtime_containment
      assert_destination_chaos_contract
      assert_discovered_chaos_contracts
      assert_emitter_chaos_contract
      catalog
      raiser
    ].sort.freeze

    def setup
      reset_julewire!
    end

    def test_capture_destination_captures_record_hashes
      destination = Julewire::Core::Testing.configure_capture_destination

      Julewire.emit(event: "test.event", source: "test", payload: { value: 1 })

      assert_equal "test.event", destination.records.fetch(0).fetch(:event)
      assert_equal({ value: 1 }, destination.records.fetch(0).fetch(:payload))
      assert_equal({ status: :ok, counts: { captured: 1 } }, destination.health)
    end

    def test_testing_alias_points_to_shipped_testing_support
      assert_same Julewire::Core::Testing, Julewire::Testing
      assert_same Julewire::Core::Testing::Chaos, Julewire::Testing::Chaos
      assert_same Julewire::Core::Testing::Contracts, Julewire::Testing::Contracts
      assert_same Julewire::Core::Testing::Coverage, Julewire::Testing::Coverage
    end

    def test_capture_destination_can_keep_record_objects
      destination = Julewire::Core::Testing.configure_capture_destination(snapshot: false)

      Julewire.emit(event: "test.event", source: "test", payload: { value: 1 })

      assert_instance_of Julewire::Core::Records::Record, destination.records.fetch(0)
    end

    def test_capture_helper_returns_records_and_yields_them
      yielded = nil

      records = Julewire::Core::Testing.capture do |captured|
        yielded = captured
        Julewire.emit(message: "captured")
      end

      assert_same yielded, records
      assert_equal "captured", records.fetch(0).fetch(:message)
    end

    def test_null_output_accepts_serialized_lines
      output = Julewire::Core::Testing::NullOutput.new

      assert_equal 5, output.write("hello")
      assert_equal ["hello"], output.writes
      assert output.flush
      assert output.close
    end

    def test_with_overridden_singleton_method_restores_existing_method
      object = Object.new
      object.define_singleton_method(:value) { :old }

      Julewire::Core::Testing.with_overridden_singleton_method(object, :value, proc { :new }) do
        assert_equal :new, object.value
      end

      assert_equal :old, object.value
    end

    def test_with_overridden_singleton_method_removes_temporary_method
      object = Object.new

      Julewire::Core::Testing.with_overridden_singleton_method(object, :temporary, proc { :new }) do
        assert_equal :new, object.temporary
      end

      refute_respond_to object, :temporary
    end

    def test_public_contract_helpers_are_available_to_adapter_tests
      assert_includes Julewire::Core::Testing::Contracts.instance_methods, :assert_julewire_formatter_contract
      assert_includes Julewire::Core::Testing::Contracts.instance_methods, :assert_julewire_execution_boundary_contract
      assert_includes Julewire::Core::Testing::Contracts.instance_methods, :assert_julewire_propagation_contract
      assert_includes Julewire::Core::Testing::Contracts.instance_methods, :assert_julewire_record_shape_contract
      assert_includes Julewire::Core::Testing::Contracts.instance_methods, :assert_julewire_record_source_contract
      assert_includes Julewire::Core::Testing::Contracts.instance_methods, :assert_julewire_integration_spi_contract
      assert_includes Julewire::Core::Testing::Contracts.instance_methods, :assert_julewire_validation_spi_contract
      assert_includes(
        Julewire::Core::Testing::Contracts.instance_methods,
        :assert_julewire_truncation_marker_spi_contract
      )
      assert_includes(
        Julewire::Core::Testing::Contracts.instance_methods,
        :assert_julewire_bounded_transform_spi_contract
      )
    end

    def test_public_contract_helpers_are_documented
      docs = File.read(File.expand_path("../../docs/contracts.md", __dir__))
      helpers = Julewire::Core::Testing::Contracts.instance_methods.grep(/\Aassert_julewire_/).sort
      documented = docs.scan(/`(assert_julewire_[^`]+)`/).flatten.map(&:to_sym)

      helpers.each { assert_includes documented, it }
      documented.each { assert_includes helpers, it }
    end

    def test_public_chaos_helpers_are_documented
      docs = File.read(File.expand_path("../../docs/contracts.md", __dir__))
      helper_methods = Julewire::Core::Testing::Chaos.singleton_class.public_instance_methods(false)
      helpers = helper_methods.grep(/\A(?:assert_.+|catalog|raiser)\z/).sort
      documented = docs.scan(/^- `([^`]+)`/).flatten.map(&:to_sym)
                       .select { CHAOS_HELPERS.include?(it) }.sort

      assert_equal CHAOS_HELPERS, helpers
      assert_equal CHAOS_HELPERS, documented
    end

    def test_stable_facade_methods_are_documented
      docs = File.read(File.expand_path("../../docs/contracts.md", __dir__))
      documented = docs.scan(/`Julewire\.([^`]+)`/).flatten.map(&:to_sym)
                       .select { STABLE_FACADE_METHODS.include?(it) }.uniq.sort

      assert_equal STABLE_FACADE_METHODS, documented
      STABLE_FACADE_METHODS.each { assert_respond_to Julewire, it }
    end
  end
end
