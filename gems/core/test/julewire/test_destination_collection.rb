# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestDestinationCollection < Minitest::Test
    cover Julewire::Core::Destinations::Collection
    cover "Julewire::Core::Destinations::Collection#before_fork!"
    cover "Julewire::Core::Destinations::Collection#cancel_before_fork!"
    cover "Julewire::Core::Destinations::Collection#empty?"

    EqualIdentity = Data.define(:name) do
      def hash = 1

      def eql?(_other) = true
    end

    class TestDestination
      attr_reader :events, :name

      def initialize(name:, emit_result: nil, flush_result: true, close_result: true, identity: nil, failures: {})
        @name = name
        @emit_result = emit_result
        @flush_result = flush_result
        @close_result = close_result
        @identity = identity
        @failures = failures
        @events = []
      end

      def emit(record)
        events << [:emit, record]
        raise @failures.fetch(:emit) if @failures.key?(:emit)

        @emit_result
      end

      def flush(timeout: nil)
        events << [:flush, timeout]
        raise @failures.fetch(:flush) if @failures.key?(:flush)

        @flush_result
      end

      def close(timeout: nil)
        events << [:close, timeout]
        raise @failures.fetch(:close) if @failures.key?(:close)

        @close_result
      end

      def after_fork!
        events << [:after_fork]
        raise @failures.fetch(:after_fork) if @failures.key?(:after_fork)

        self
      end

      def before_fork!(timeout: nil)
        events << [:before_fork, timeout]
        raise @failures.fetch(:before_fork) if @failures.key?(:before_fork)

        self
      end

      def health
        raise @failures.fetch(:health) if @failures.key?(:health)

        { status: :ok, events: events.length }
      end

      def resource_identity = @identity || self
    end

    class NoAfterForkDestination < TestDestination
      undef_method :after_fork!
    end

    class NoBeforeForkDestination < TestDestination
      undef_method :before_fork!
    end

    class FallbackDestination < TestDestination
      def name
        raise "name failed"
      end

      undef_method :resource_identity
    end

    class ResourceIdentityFailingDestination < TestDestination
      def resource_identity
        raise "identity failed"
      end
    end

    class DestinationList
      attr_reader :defaults

      def initialize(destinations)
        @destinations = destinations
      end

      def build(defaults:)
        @defaults = defaults
        @destinations
      end
    end

    class Configuration
      attr_reader :destinations

      def initialize(destinations)
        @destinations = DestinationList.new(destinations)
      end
    end

    def test_build_validates_destination_contracts
      error = assert_raises(ArgumentError) do
        build_collection([Object.new])
      end

      assert_equal "destination must respond to #name", error.message
    end

    def test_initializer_copies_destinations_before_freezing
      first = TestDestination.new(name: :first)
      second = TestDestination.new(name: :second)
      destinations = [first]
      collection = collection_for(destinations)

      destinations << second
      collection.emit(record)

      assert_predicate collection.instance_variable_get(:@destinations), :frozen?
      assert_equal [[:emit, record]], first.events
      assert_empty second.events
    end

    def test_empty_reports_destination_presence
      assert_predicate collection_for([]), :empty?
      refute_predicate collection_for([TestDestination.new(name: :first)]), :empty?
    end

    def test_after_fork_returns_self_and_continues_after_failures
      failures = Queue.new
      first = TestDestination.new(name: :first, failures: { after_fork: RuntimeError.new("fork failed") })
      second = TestDestination.new(name: :second)
      collection = collection_for([first, second], on_failure: ->(error, metadata) { failures << [error, metadata] })

      assert_same collection, collection.after_fork!

      error, metadata = safe_queue_pop(failures)

      assert_equal "fork failed", error.message
      assert_equal :after_fork, metadata.fetch(:action)
      assert_equal :first, metadata.fetch(:destination)
      assert_equal :destination_lifecycle, metadata.fetch(:phase)
      assert_equal [[:after_fork]], first.events
      assert_equal [[:after_fork]], second.events
    end

    def test_after_fork_skips_destinations_without_hook
      failures = Queue.new
      destination = NoAfterForkDestination.new(name: :plain)
      collection = collection_for([destination], on_failure: ->(error, metadata) { failures << [error, metadata] })

      assert_same collection, collection.after_fork!

      assert_empty destination.events
      assert_empty failures
    end

    def test_after_fork_propagates_unsafe_fork_errors
      error = Julewire::Core::UnsafeForkError.new("unsafe")
      destination = TestDestination.new(name: :ractor, failures: { after_fork: error })
      collection = collection_for([destination])

      raised = assert_raises(Julewire::Core::UnsafeForkError) { collection.after_fork! }

      assert_same error, raised
    end

    def test_before_fork_is_idempotent_and_cancel_resumes_only_prepared_destinations
      first = TestDestination.new(name: :first)
      plain = NoBeforeForkDestination.new(name: :plain)
      collection = collection_for([first, plain])

      assert_same collection, collection.before_fork!(timeout: 0.25)
      assert_same collection, collection.before_fork!(timeout: 0.25)
      assert_same collection, collection.cancel_before_fork!

      before_event = first.events.fetch(0)

      assert_equal :before_fork, before_event.fetch(0)
      assert_operator before_event.fetch(1), :<=, 0.25
      assert_equal [:after_fork], first.events.fetch(1)
      assert_empty plain.events
    end

    def test_before_fork_failure_resumes_destinations_prepared_earlier
      first = TestDestination.new(name: :first)
      second = TestDestination.new(name: :second, failures: { before_fork: RuntimeError.new("unsafe") })
      collection = collection_for([first, second])

      error = assert_raises(RuntimeError) { collection.before_fork! }

      assert_equal "unsafe", error.message
      assert_equal [[:before_fork, nil], [:after_fork]], first.events
      assert_equal [[:before_fork, nil], [:after_fork]], second.events
    end

    def test_lifecycle_methods_accept_default_timeout_and_validate_named_timeout
      destination = TestDestination.new(name: :default)
      collection = collection_for([destination])

      assert_true collection.flush
      assert_true collection.close
      assert_true collection.close(timeout: 0.25)

      error = assert_raises(ArgumentError) { collection.flush(timeout: -1) }

      assert_equal [[:flush, nil], [:close, nil]], destination.events.first(2)
      assert_equal :close, destination.events.fetch(2).fetch(0)
      remaining = destination.events.fetch(2).fetch(1)

      assert_operator remaining, :>, 0
      assert_operator remaining, :<=, 0.25
      assert_equal "timeout must be nil or a non-negative finite Numeric", error.message
    end

    def test_zero_timeout_attempts_first_destination_only
      first = TestDestination.new(name: :first)
      second = TestDestination.new(name: :second)
      collection = collection_for([first, second])

      assert_false collection.flush(timeout: 0)

      assert_equal [[:flush, 0]], first.events
      assert_empty second.events
    end

    def test_positive_timeout_attempts_later_destinations
      first = TestDestination.new(name: :first)
      second = TestDestination.new(name: :second)
      collection = collection_for([first, second])

      assert_true collection.flush(timeout: 2)

      assert_equal 1, first.events.length
      assert_equal 1, second.events.length
      assert_operator first.events.fetch(0).fetch(1), :>, 1
      assert_operator second.events.fetch(0).fetch(1), :>, 1
    end

    def test_false_lifecycle_result_marks_collection_failure_but_continues
      first = TestDestination.new(name: :first, flush_result: false)
      second = TestDestination.new(name: :second)
      collection = collection_for([first, second])

      assert_false collection.flush

      assert_equal [[:flush, nil]], first.events
      assert_equal [[:flush, nil]], second.events
    end

    def test_lifecycle_failures_report_destination_metadata
      failures = Queue.new
      destination = TestDestination.new(name: :broken, failures: { flush: RuntimeError.new("flush failed") })
      collection = collection_for([destination], on_failure: ->(error, metadata) { failures << [error, metadata] })

      assert_false collection.flush(timeout: 0.25)

      error, metadata = safe_queue_pop(failures)

      assert_equal "flush failed", error.message
      assert_equal :flush, metadata.fetch(:action)
      assert_equal :broken, metadata.fetch(:destination)
      assert_equal :destination_lifecycle, metadata.fetch(:phase)
    end

    def test_lifecycle_resource_identity_failures_are_reported_as_output_lifecycle_failures
      failures = Queue.new
      destination = ResourceIdentityFailingDestination.new(name: :identity)
      collection = collection_for([destination], on_failure: ->(error, metadata) { failures << [error, metadata] })

      assert_false collection.close(skip_resource_identities: {}.compare_by_identity)

      error, metadata = safe_queue_pop(failures)

      assert_equal "identity failed", error.message
      assert_equal :close, metadata.fetch(:action)
      assert_equal :output_lifecycle, metadata.fetch(:phase)
      assert_false metadata.key?(:destination)
    end

    def test_lifecycle_resource_identities_use_identity_hashing
      first_identity = EqualIdentity.new(:first)
      second_identity = EqualIdentity.new(:second)
      identities = collection_for([
                                    TestDestination.new(name: :first, identity: first_identity),
                                    TestDestination.new(name: :second, identity: second_identity)
                                  ]).lifecycle_resource_identities

      assert_equal 2, identities.length
      assert_true identities.key?(first_identity)
      assert_true identities.key?(second_identity)
      assert_equal [true, true], identities.values
    end

    def test_close_skips_destinations_by_resource_identity
      shared_identity = Object.new
      skipped = TestDestination.new(name: :skipped, identity: shared_identity)
      closed = TestDestination.new(name: :closed)
      collection = collection_for([skipped, closed])

      assert_true collection.close(skip_resource_identities: { shared_identity => true }.compare_by_identity)

      assert_empty skipped.events
      assert_equal [[:close, nil]], closed.events
    end

    def test_resource_identity_falls_back_to_destination_object
      destination = FallbackDestination.new(name: :fallback)
      identities = collection_for([destination]).lifecycle_resource_identities

      assert_true identities.key?(destination)
    end

    def test_health_failure_uses_fallback_destination_name
      destination = FallbackDestination.new(name: :fallback, failures: { health: RuntimeError.new("health failed") })
      health = collection_for([destination]).health.fetch("Julewire::TestDestinationCollection::FallbackDestination")

      assert_equal :unknown, health.fetch(:status)
      assert_equal "destination", health.fetch(:type)
      assert_equal "RuntimeError", health.dig(:last_failure, :class)
      assert_equal "Julewire::TestDestinationCollection::FallbackDestination", health.dig(:last_failure, :destination)
      assert_equal :destination_health, health.dig(:last_failure, :phase)
    end

    def test_emit_false_and_exception_results_report_drop_metadata
      drops = Queue.new
      failures = Queue.new
      accepting = TestDestination.new(name: :accepting)
      rejecting = TestDestination.new(name: :rejecting, emit_result: false)
      raising = TestDestination.new(name: :raising, failures: { emit: RuntimeError.new("emit failed") })
      collection = collection_for(
        [accepting, rejecting, raising],
        **queue_callbacks(drops: drops, failures: failures)
      )

      collection.emit(record)

      rejected_reason, rejected_metadata = safe_queue_pop(drops)
      error, failure_metadata = safe_queue_pop(failures)
      exception_reason, exception_metadata = safe_queue_pop(drops)

      assert_equal :destination_rejected, rejected_reason
      assert_equal :destination, rejected_metadata.fetch(:phase)
      assert_equal :rejecting, rejected_metadata.fetch(:destination)
      assert_instance_of Hash, rejected_metadata.fetch(:record_metadata)
      assert_equal "work", rejected_metadata.dig(:record_metadata, :event)
      assert_equal "emit failed", error.message
      assert_equal :destination, failure_metadata.fetch(:phase)
      assert_equal :raising, failure_metadata.fetch(:destination)
      assert_equal :destination_exception, exception_reason
      assert_equal :destination, exception_metadata.fetch(:phase)
      assert_equal :raising, exception_metadata.fetch(:destination)
      assert_instance_of Hash, exception_metadata.fetch(:record_metadata)
      assert_equal "work", exception_metadata.dig(:record_metadata, :event)
      assert_empty drops
    end

    def test_build_forwards_defaults_and_callbacks
      drops = Queue.new
      failures = Queue.new
      rejecting = TestDestination.new(name: :rejecting, emit_result: false)
      raising = TestDestination.new(name: :raising, failures: { emit: RuntimeError.new("emit failed") })
      configuration = Configuration.new([rejecting, raising])
      defaults = { formatter: :formatter }

      collection = Julewire::Core::Destinations::Collection.build(
        configuration: configuration,
        defaults: defaults,
        on_drop: ->(reason, metadata) { drops << [reason, metadata] },
        on_failure: ->(error, metadata) { failures << [error, metadata] }
      )

      collection.emit(record)

      assert_same defaults, configuration.destinations.defaults
      assert_equal :destination_rejected, safe_queue_pop(drops).fetch(0)
      assert_equal "emit failed", safe_queue_pop(failures).fetch(0).message
      assert_equal :destination_exception, safe_queue_pop(drops).fetch(0)
    end

    private

    def record
      @record ||= build_record({ event: "work", message: "work" })
    end

    def build_collection(destinations)
      Julewire::Core::Destinations::Collection.build(
        configuration: Configuration.new(destinations),
        defaults: {},
        on_drop: ->(*) {},
        on_failure: ->(*) {}
      )
    end

    def collection_for(destinations, on_drop: ->(*) {}, on_failure: ->(*) {})
      Julewire::Core::Destinations::Collection.new(destinations, on_drop: on_drop, on_failure: on_failure)
    end
  end
end
