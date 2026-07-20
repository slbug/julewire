# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestCoreRuntimeRegistry < Minitest::Test
    cover "Julewire::Core::RuntimeRegistry.fetch"
    cover "Julewire::Core::RuntimeRegistry.reset"
    cover "Julewire::Core::Runtime#reset_facade!"
    class ReentrantCloseOutput
      def initialize(looked_up:, name:, release:)
        @looked_up = looked_up
        @name = name
        @release = release
      end

      def write(value) = value.bytesize

      def close
        @looked_up << Julewire.runtime(@name)
        @release.pop
      end
    end

    def test_runtime_name_validation_uses_public_runtime_wording
      type_error = assert_raises(ArgumentError) { Julewire.runtime(Object.new) }
      empty_error = assert_raises(ArgumentError) { Julewire.runtime("") }

      assert_equal "runtime name must be a String or Symbol", type_error.message
      assert_equal "runtime name must not be empty", empty_error.message
    end

    def test_named_runtime_requires_core_runtime
      current = Object.new

      Julewire::Core::RuntimeLocator.current = current

      assert_same current, Julewire.runtime
      error = assert_raises(Julewire::Core::Error) { Julewire.runtime(:audit) }
      assert_equal "named Julewire runtimes are not available from the current runtime", error.message
    ensure
      Julewire::Core::RuntimeLocator.current = Julewire::Core::Runtime.new
    end

    def test_named_runtime_registry_accepts_runtime_subclasses_as_current_runtime
      runtime = Class.new(Julewire::Core::Runtime).new

      named = Julewire::Core::RuntimeRegistry.fetch(:subclass_current, current: runtime)

      assert_instance_of Julewire::Core::Runtime, named
    end

    def test_named_runtime_registry_memoizes_one_runtime_across_threads
      registry = Julewire::Core::RuntimeRegistry
      threads = Array.new(8) do
        safe_thread { registry.fetch(:concurrent_probe, current: Julewire.runtime) }
      end
      runtimes = safe_thread_values(threads)

      assert_equal 1, runtimes.map(&:object_id).uniq.length
    end

    def test_global_reset_closes_and_discards_named_runtimes
      primary = Julewire.runtime
      default_level = primary.config.level
      primary.configure { |config| config.level = default_level == :error ? :debug : :error }
      original = Julewire.runtime(:reset_probe)
      original.configure { |config| config.level = :error }

      result = Julewire.reset!

      replacement = Julewire.runtime(:reset_probe)

      assert_nil result
      assert_same primary, Julewire.runtime
      assert_equal default_level, primary.config.level
      assert_equal default_level, original.config.level
      refute_same original, replacement
    end

    def test_global_reset_publishes_fresh_registry_before_named_runtime_teardown
      name = :atomic_reset_probe
      looked_up = Queue.new
      release = Queue.new
      original = Julewire.runtime(name)
      original.configure do |config|
        configure_destination(
          config,
          close_output: true,
          output: ReentrantCloseOutput.new(looked_up: looked_up, name: name, release: release)
        )
      end
      reset_thread = safe_thread { Julewire.reset! }
      replacement = safe_queue_pop(looked_up)
      fetch_thread = safe_thread { Julewire.runtime(name) }

      assert fetch_thread.join(0.05), "named lookup remained blocked during detached runtime teardown"
      assert_same replacement, safe_thread_value(fetch_thread)
      refute_same original, replacement
      release << true

      assert_nil safe_thread_value(reset_thread)
      assert_same replacement, Julewire.runtime(name)
    ensure
      release&.push(true) if reset_thread&.alive?
      cleanup_thread(reset_thread)
      cleanup_thread(fetch_thread)
    end
  end
end
