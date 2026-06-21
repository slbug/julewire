# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestDestinationFactories < Minitest::Test
    cover Julewire::Core::Destinations::Definition
    cover Julewire::Core::Destinations::Registry

    class FactoryDestination
      attr_reader :name, :records, :resource_identity

      def initialize(name, resource_identity: nil)
        @name = name
        @records = []
        @resource_identity = resource_identity || self
      end

      def emit(record)
        records << record
      end

      def flush(timeout: nil); end

      def close(timeout: nil); end

      def health
        {
          status: :ok,
          records: records.length
        }
      end
    end

    class BareFactoryDestination
      attr_reader :name, :records

      def initialize(name)
        @name = name
        @records = []
      end

      def emit(record)
        records << record
      end

      def flush(timeout: nil); end

      def close(timeout: nil); end

      def health
        {
          status: :ok,
          records: records.length
        }
      end
    end

    def test_registered_destination_factory_builds_destination_with_adapter_options
      kind = :"registered_destination_#{object_id.abs}"
      built = []
      on_drop = ->(*) {}
      on_failure = ->(*) {}

      Julewire::Core::Destinations.register(kind) do |name:, token:, on_drop:, on_failure:|
        built << { name: name, token: token, on_drop: on_drop, on_failure: on_failure }
        FactoryDestination.new(name)
      end

      Julewire.configure do |config|
        config.on_drop = on_drop
        config.on_failure = on_failure
        config.destinations.use(kind, name: :factory_destination, token: "adapter-specific")
      end

      Julewire.emit(message: "work")

      assert_equal(
        [{ name: :factory_destination, token: "adapter-specific", on_drop: on_drop, on_failure: on_failure }],
        built
      )
      assert_equal 1, Julewire.health.dig(:pipeline, :destinations, :factory_destination, :records)
    ensure
      Julewire::Testing.unregister_destination(kind) if kind
    end

    def test_registered_destination_factory_uses_kind_as_default_name
      kind = :"default_name_destination_#{object_id.abs}"
      built = []

      Julewire::Core::Destinations.register(kind) do |name:, **|
        built << name
        FactoryDestination.new(name)
      end

      Julewire.configure do |config|
        config.destinations.use(kind)
      end

      Julewire.emit(message: "work")

      assert_equal [kind], built
      assert_equal 1, Julewire.health.dig(:pipeline, :destinations, kind, :records)
    ensure
      Julewire::Testing.unregister_destination(kind) if kind
    end

    def test_registered_destination_factory_keeps_explicit_callbacks
      kind = :"callback_destination_#{object_id.abs}"
      default_drop = ->(*) {}
      default_failure = ->(*) {}
      explicit_drop = ->(*) {}
      explicit_failure = ->(*) {}
      built = []

      Julewire::Core::Destinations.register(kind) do |on_drop:, on_failure:, **|
        built << [on_drop, on_failure]
        FactoryDestination.new(:callback_destination)
      end

      Julewire.configure do |config|
        config.on_drop = default_drop
        config.on_failure = default_failure
        config.destinations.use(kind, on_drop: explicit_drop, on_failure: explicit_failure)
      end

      Julewire.emit(message: "work")

      assert_equal [[explicit_drop, explicit_failure]], built
    ensure
      Julewire::Testing.unregister_destination(kind) if kind
    end

    def test_registered_destination_factory_rejects_shared_resource_identity
      kind = :"shared_resource_destination_#{object_id.abs}"
      resource = Object.new

      Julewire::Core::Destinations.register(kind) do |name:, **|
        FactoryDestination.new(name, resource_identity: resource)
      end

      error = assert_raises(ArgumentError) do
        configure_two_destinations(kind)
      end

      assert_equal(
        "destination :two shares output with destination :one; use a transport adapter for shared sinks",
        error.message
      )
    ensure
      Julewire::Testing.unregister_destination(kind) if kind
    end

    def test_registered_destination_factory_allows_distinct_resource_identities
      kind = :"distinct_resource_destination_#{object_id.abs}"
      resources = {}

      Julewire::Core::Destinations.register(kind) do |name:, **|
        FactoryDestination.new(name, resource_identity: (resources[name] ||= Object.new))
      end

      configure_two_destinations(kind)

      Julewire.emit(message: "work")

      assert_equal 1, Julewire.health.dig(:pipeline, :destinations, :one, :records)
      assert_equal 1, Julewire.health.dig(:pipeline, :destinations, :two, :records)
    ensure
      Julewire::Testing.unregister_destination(kind) if kind
    end

    def test_registered_destination_factory_accepts_destinations_without_resource_identity
      kind = :"bare_resource_destination_#{object_id.abs}"

      Julewire::Core::Destinations.register(kind) { |name:, **| BareFactoryDestination.new(name) }

      configure_two_destinations(kind)

      Julewire.emit(message: "work")

      assert_equal 1, Julewire.health.dig(:pipeline, :destinations, :one, :records)
      assert_equal 1, Julewire.health.dig(:pipeline, :destinations, :two, :records)
    ensure
      Julewire::Testing.unregister_destination(kind) if kind
    end

    def test_registered_destination_factory_does_not_require_callback_defaults
      kind = :"minimal_destination_factory_#{object_id.abs}"
      built = []

      Julewire::Core::Destinations.register(kind) do |name:|
        built << name
        FactoryDestination.new(name)
      end

      destination = Julewire::Core::Destinations::Definition.new(kind).build(defaults: {}, output_identities: {})

      assert_equal [kind], built
      assert_instance_of FactoryDestination, destination
    ensure
      Julewire::Testing.unregister_destination(kind) if kind
    end

    def test_registered_destination_factory_must_return_destination_contract
      kind = :"bad_destination_factory_#{object_id.abs}"

      Julewire::Core::Destinations.register(kind) { "not a destination" }

      error = assert_raises(ArgumentError) do
        Julewire.configure do |config|
          config.destinations.use(kind)
        end
      end

      assert_equal "destination must respond to #name", error.message
    ensure
      Julewire::Testing.unregister_destination(kind) if kind
    end

    def test_registered_destination_factory_can_be_removed
      kind = :"temporary_destination_#{object_id.abs}"

      Julewire::Core::Destinations.register(kind) { |name:, **| FactoryDestination.new(name) }

      assert_instance_of Proc, Julewire::Core::Destinations.factory_for(kind)

      Julewire::Testing.unregister_destination(kind)

      assert_nil Julewire::Core::Destinations.factory_for(kind)
    end

    private

    def configure_two_destinations(kind)
      Julewire.configure do |config|
        config.destinations.use(kind, name: :one)
        config.destinations.use(kind, name: :two)
      end
    end
  end
end
