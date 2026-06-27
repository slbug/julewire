# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestCoreLocalStorage < Minitest::Test
    cover Julewire::Core::RuntimeLocator
    cover Julewire::Core::LocalStorage
    def test_runtime_locator_uses_local_storage_in_main_ractor
      skip "Ractor-local storage is not available" unless ractor_storage_available?

      runtime = Julewire::Core::Runtime.new

      Julewire::Core::RuntimeLocator.current = runtime

      assert_same runtime, Julewire::Core::RuntimeLocator.current
      assert_same runtime, Julewire::Core::LocalStorage.runtime
    end

    def test_local_storage_runtime_builds_and_memoizes_default_runtime
      Julewire::Core::LocalStorage.runtime = nil

      runtime = Julewire::Core::LocalStorage.runtime

      assert_instance_of Julewire::Core::Runtime, runtime
      assert_same runtime, Julewire::Core::LocalStorage.runtime
    end

    def test_local_storage_runtime_memoizes_one_default_across_contending_threads
      local_storage = Julewire::Core::LocalStorage
      previous_runtime = local_storage.runtime
      local_storage.runtime = nil
      ready = Queue.new
      start = Queue.new
      threads = Array.new(8) do
        safe_thread do
          ready << true
          start.pop
          local_storage.runtime
        rescue StandardError => e
          e
        end
      end
      8.times { safe_queue_pop(ready) }
      8.times { start << true }
      runtimes = safe_thread_values(threads)

      assert_false runtimes.any?(Exception), runtimes.grep(Exception).map(&:full_message).join("\n")
      assert_equal 1, runtimes.map(&:object_id).uniq.length
      assert_same runtimes.first, local_storage.runtime
    ensure
      threads&.each { cleanup_thread(it) }
      local_storage.runtime = previous_runtime if local_storage && previous_runtime
    end

    def test_local_storage_ractor_calls_resolve_top_level_ractor
      local_storage = Julewire::Core::LocalStorage
      fake_ractor = Module.new do
        class << self
          def main? = raise "wrong Ractor constant"

          def store_if_absent(*) = raise "wrong Ractor constant"

          def []=(*)
            raise "wrong Ractor constant"
          end
        end
      end

      without_constant(Julewire, :Ractor) do
        Julewire.const_set(:Ractor, fake_ractor)

        assert_false local_storage.__send__(:ractor_local_storage?)
        result = ::Ractor.new do
          runtime = Julewire::Core::Runtime.new
          Julewire::Core::LocalStorage.runtime = runtime
          [Julewire::Core::LocalStorage.runtime.equal?(runtime),
           Julewire::Core::LocalStorage.__send__(:ractor_runtime).equal?(runtime)]
        end.value

        assert_equal [true, true], result
      end
    end

    def test_local_storage_ractor_runtime_builds_and_memoizes_runtime
      skip "Ractor-local storage is not available" unless ractor_storage_available?

      result = Ractor.new do
        first = Julewire::Core::LocalStorage.__send__(:ractor_runtime)
        second = Julewire::Core::LocalStorage.__send__(:ractor_runtime)
        [first.class.name, first.equal?(second)]
      end.value

      assert_equal ["Julewire::Core::Runtime", true], result
    end

    def test_local_storage_ractor_context_store_is_memoized_per_thread
      skip "Ractor-local storage is not available" unless ractor_storage_available?

      result = Ractor.new do
        store = Julewire::Core::LocalStorage.context_store
        other_thread_store = Thread.new { Julewire::Core::LocalStorage.context_store }.value
        [store.class.name,
         store.equal?(Julewire::Core::LocalStorage.context_store),
         store.equal?(other_thread_store)]
      end.value

      assert_equal ["Julewire::Core::ContextStore", true, false], result
    end

    def test_local_storage_context_store_is_isolated_per_fiber
      Julewire.context.add(main: true)

      inside_fiber = Fiber.new { Julewire.context.to_h }.resume

      assert_empty inside_fiber
      assert_equal({ main: true }, Julewire.context.to_h)
    end

    def test_context_store_reset_replaces_the_current_fiber_store
      previous = Julewire::Core::LocalStorage.context_store
      Julewire.context.add(request_id: "req-1")

      Julewire::Core::ContextStore.reset_current!

      refute_same previous, Julewire::Core::LocalStorage.context_store
      assert_empty Julewire.context.to_h
    end

    private

    def ractor_storage_available?
      defined?(Ractor) &&
        Ractor.respond_to?(:store_if_absent) &&
        Ractor.respond_to?(:[])
    end
  end
end
