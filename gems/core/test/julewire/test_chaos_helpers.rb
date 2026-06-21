# frozen_string_literal: true

require "test_helper"
require "julewire/core/testing"

module Julewire
  class TestChaosHelpers < Minitest::Test
    cover Julewire::Core::Testing::Chaos
    cover Julewire::Core::Testing::Chaos::Catalog
    cover Julewire::Core::Testing::Chaos::Destination
    cover Julewire::Core::Testing::Chaos::Emitter

    class DestinationProbe
      def initialize(events, scenario)
        @events = events
        @scenario = scenario
      end

      def emit(record)
        @events << [:emit, @scenario, record.fetch(:message)]
        nil
      end

      def close(timeout:)
        @events << [:close, @scenario, timeout]
        nil
      end
    end

    def setup
      reset_julewire!
    end

    def test_assert_contained_exercises_standard_error_corpus
      exercised = []

      result = Julewire::Testing::Chaos.assert_contained(self) do |error|
        exercised << error.class
      end

      assert_nil result
      assert_equal [RuntimeError, ArgumentError, TypeError], exercised
    end

    def test_assert_contained_requires_block
      error = assert_raises(ArgumentError) { Julewire::Testing::Chaos.assert_contained(self) }

      assert_equal "block required", error.message
    end

    def test_assert_contained_reports_leaks
      error = assert_raises(Minitest::Assertion) do
        Julewire::Testing::Chaos.assert_contained(self, errors: [RuntimeError.new("boom")]) do |failure|
          raise failure
        end
      end

      assert_equal "expected RuntimeError to be contained, leaked RuntimeError: boom", error.message
    end

    def test_destination_contract_exercises_builders_and_closes_destinations
      events = []
      error = RuntimeError.new("boom")

      result = Julewire::Testing::Chaos.assert_destination_chaos_contract(
        self,
        record: build_record({ message: "destination-chaos" }),
        formatter: destination_builder(events, :formatter),
        encoder: destination_builder(events, :encoder),
        output: destination_builder(events, :output),
        callbacks: destination_builder(events, :callbacks),
        errors: [error]
      )

      assert_nil result
      assert_equal expected_destination_events(error), events
    end

    def test_destination_contract_skips_nil_callback_builder
      events = []

      Julewire::Testing::Chaos.assert_destination_chaos_contract(
        self,
        record: build_record({ message: "destination-chaos" }),
        formatter: destination_builder(events, :formatter),
        encoder: destination_builder(events, :encoder),
        output: destination_builder(events, :output),
        callbacks: nil,
        errors: [RuntimeError.new("boom")]
      )

      refute_includes events.map { it.fetch(1) }, :callbacks
    end

    def test_destination_contract_reports_failed_scenario
      %i[formatter encoder output callbacks].each do |scenario|
        error = assert_raises(Minitest::Assertion) do
          Julewire::Testing::Chaos.assert_destination_chaos_contract(
            self,
            record: build_record({ message: "destination-chaos" }),
            **destination_failure_builders(scenario),
            errors: [RuntimeError.new("boom")]
          )
        end

        assert_equal(
          "expected destination #{scenario} chaos to be contained, leaked RuntimeError: builder failed",
          error.message
        )
      end
    end

    def test_emitter_contract_exercises_builder_and_framework_exercise
      events = []
      error = RuntimeError.new("boom")

      result = Julewire::Testing::Chaos.assert_emitter_chaos_contract(
        self,
        component: :subscriber,
        build: lambda do |failure|
          events << [:build, failure]
          Object.new
        end,
        exercise: ->(_emitter, failure) { events << [:exercise, failure] },
        errors: [error]
      )

      assert_nil result
      assert_equal [[:build, error], [:exercise, error]], events
    end

    def test_emitter_contract_exercises_default_standard_error_corpus
      exercised = []

      result = Julewire::Testing::Chaos.assert_emitter_chaos_contract(
        self,
        component: :subscriber,
        build: ->(failure) { failure },
        exercise: ->(_emitter, failure) { exercised << failure.class }
      )

      assert_nil result
      assert_equal [RuntimeError, ArgumentError, TypeError], exercised
    end

    def test_emitter_contract_reports_component_failures
      error = assert_raises(Minitest::Assertion) do
        Julewire::Testing::Chaos.assert_emitter_chaos_contract(
          self,
          component: :listener,
          build: ->(_failure) { Object.new },
          exercise: ->(_emitter, _failure) { raise "listener failed" },
          errors: [RuntimeError.new("boom")]
        )
      end

      assert_equal "expected listener chaos to be contained, leaked RuntimeError: listener failed", error.message
    end

    def test_raiser_builds_raising_callable
      error = RuntimeError.new("boom")
      callable = Julewire::Testing::Chaos.raiser(error)

      assert_same error, assert_raises(RuntimeError) { callable.call }
    end

    def test_core_runtime_containment_exercises_curated_surfaces
      Julewire::Testing::Chaos.assert_core_runtime_containment(
        self,
        errors: [RuntimeError.new("boom")]
      )
    end

    def test_catalog_contract_exercises_registered_component_kinds
      events = []
      error = RuntimeError.new("boom")
      catalog = Julewire::Testing::Chaos.catalog do |components|
        components.processor(:mask) { |failure| events << [:processor, failure] }
        components.formatter(:json) { |failure| events << [:formatter, failure] }
        components.encoder(:json) { |failure| events << [:encoder, failure] }
        components.destination(:stdout) { |failure| events << [:destination, failure] }
        components.subscriber(:web) { |failure| events << [:subscriber, failure] }
        components.listener(:message_bus) { |failure| events << [:listener, failure] }
      end

      result = Julewire::Testing::Chaos.assert_discovered_chaos_contracts(
        self,
        catalog: catalog,
        errors: [error]
      )

      assert_nil result
      assert_equal(
        %i[processor formatter encoder destination subscriber listener],
        events.map { it.fetch(0) }
      )
      assert_equal [error], events.map { it.fetch(1) }.uniq
    end

    def test_catalog_contract_reports_named_component_failures
      catalog = Julewire::Testing::Chaos.catalog do |components|
        components.processor(:mask) { |_failure| raise "processor failed" }
      end

      error = assert_raises(Minitest::Assertion) do
        Julewire::Testing::Chaos.assert_discovered_chaos_contracts(
          self,
          catalog: catalog,
          errors: [RuntimeError.new("boom")]
        )
      end

      assert_equal "expected processor mask chaos to be contained, leaked RuntimeError: processor failed", error.message
    end

    def test_catalog_contract_exercises_default_standard_error_corpus
      exercised = []
      catalog = Julewire::Testing::Chaos.catalog do |components|
        components.processor(:mask) { |failure| exercised << failure.class }
      end

      result = Julewire::Testing::Chaos.assert_discovered_chaos_contracts(self, catalog: catalog)

      assert_nil result
      assert_equal [RuntimeError, ArgumentError, TypeError], exercised
    end

    def test_catalog_contract_requires_entries
      error = assert_raises(ArgumentError) do
        Julewire::Testing::Chaos.assert_discovered_chaos_contracts(
          self,
          catalog: Julewire::Testing::Chaos.catalog,
          errors: [RuntimeError.new("boom")]
        )
      end

      assert_equal "chaos catalog must have entries", error.message
    end

    def test_catalog_rejects_entries_without_exercise_blocks
      error = assert_raises(ArgumentError) do
        Julewire::Testing::Chaos.catalog { it.processor(:mask) }
      end

      assert_equal "chaos component exercise block required", error.message
    end

    private

    def destination_builder(events, scenario)
      lambda do |error|
        events << [:builder, scenario, error]
        DestinationProbe.new(events, scenario)
      end
    end

    def expected_destination_events(error)
      %i[formatter encoder output callbacks].flat_map do |scenario|
        [
          [:builder, scenario, error],
          [:emit, scenario, "destination-chaos"],
          [:close, scenario, 0]
        ]
      end
    end

    def destination_failure_builders(failed_scenario)
      %i[formatter encoder output callbacks].to_h do |scenario|
        builder = if scenario == failed_scenario
                    ->(_error) { raise "builder failed" }
                  else
                    destination_builder([], scenario)
                  end
        [scenario, builder]
      end
    end
  end
end
