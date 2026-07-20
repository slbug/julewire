# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestConfigureGuard < Minitest::Test
    cover "Julewire::Core::FacadePrivateMethods#with_cleared_configure_guard"
    cover "Julewire::Core::Runtime#build_configured_pipeline"
    cover "Julewire::Core::Runtime#configure_guard_active?"
    cover "Julewire::Core::Runtime#reject_runtime_call_during_configure!"
    cover "Julewire::Core::Runtime#with_configure_guard"
    def test_julewire_fiber_created_inside_configure_does_not_keep_stale_guard
      output = StringIO.new
      fiber = nil

      Julewire.configure do |config|
        configure_destination(config, output: output)
        fiber = Julewire.fiber { Julewire.emit(message: "fiber") }
      end

      fiber.resume

      assert_equal "fiber", JSON.parse(output.string).fetch("message")
    end

    def test_julewire_thread_created_inside_configure_does_not_keep_stale_guard
      output = StringIO.new
      ready = Queue.new
      thread = nil

      Julewire.configure do |config|
        configure_destination(config, output: output)
        thread = safe_julewire_thread do
          ready.pop
          Julewire.emit(message: "thread")
        end
      end

      ready << true
      safe_thread_value(thread)

      assert_equal "thread", JSON.parse(output.string).fetch("message")
    end

    def test_configure_guard_clear_helper_restores_previous_guard
      guard_key = Julewire::Core::Runtime::CONFIGURE_GUARD_KEY
      previous = [:runtime, 1].freeze
      Fiber[guard_key] = previous

      Julewire.__send__(:with_cleared_configure_guard) do
        assert_nil Fiber[guard_key]
      end

      assert_same previous, Fiber[guard_key]
    ensure
      Fiber[guard_key] = nil if defined?(guard_key) && guard_key
    end

    def test_configure_guard_clear_helper_restores_previous_guard_after_error
      guard_key = Julewire::Core::Runtime::CONFIGURE_GUARD_KEY
      previous = [:runtime, 1].freeze
      Fiber[guard_key] = previous

      error = assert_raises(RuntimeError) do
        Julewire.__send__(:with_cleared_configure_guard) { raise "boom" }
      end

      assert_equal "boom", error.message
      assert_same previous, Fiber[guard_key]
    ensure
      Fiber[guard_key] = nil if defined?(guard_key) && guard_key
    end

    def test_configure_guard_reaches_nested_fibers
      Julewire.configure do |_config|
        Fiber.new do
          error = assert_raises(Julewire::Core::Error) do
            Julewire.emit(message: "nested")
          end

          assert_match "cannot be called from inside Julewire.configure", error.message
        end.resume
      end
    end

    def test_configure_rejects_nested_configure
      assert_runtime_call_rejected_inside_configure(:configure) { Julewire.configure { it.level = :debug } }
    end

    def test_configure_restores_previous_foreign_guard_token
      guard_key = Julewire::Core::Runtime::CONFIGURE_GUARD_KEY
      previous = [:foreign_runtime, 7].freeze
      Fiber[guard_key] = previous

      Julewire.configure { configure_destination(it, output: StringIO.new) }

      assert_same previous, Fiber[guard_key]
    ensure
      Fiber[guard_key] = nil if defined?(guard_key) && guard_key
    end

    def test_configure_ignores_stale_same_runtime_guard_token
      guard_key = Julewire::Core::Runtime::CONFIGURE_GUARD_KEY
      runtime = Julewire.runtime
      stale = [runtime.object_id, -1].freeze
      Fiber[guard_key] = stale

      Julewire.emit(message: "stale-token")

      assert_same stale, Fiber[guard_key]
    ensure
      Fiber[guard_key] = nil if defined?(guard_key) && guard_key
    end

    def test_configure_guard_is_scoped_to_runtime_identity
      guard_key = Julewire::Core::Runtime::CONFIGURE_GUARD_KEY
      runtime = Julewire.runtime
      foreign_runtime = Julewire::Core::Runtime.new
      generation = runtime.instance_variable_get(:@configure_generation).value
      Fiber[guard_key] = [foreign_runtime.object_id, generation].freeze

      Julewire.emit(message: "foreign-token")

      assert_equal [foreign_runtime.object_id, generation], Fiber[guard_key]
    ensure
      Fiber[guard_key] = nil if defined?(guard_key) && guard_key
    end

    def test_configure_guard_ignores_non_array_tokens
      guard_key = Julewire::Core::Runtime::CONFIGURE_GUARD_KEY
      runtime = Julewire.runtime
      generation = runtime.instance_variable_get(:@configure_generation).value
      token = Object.new
      token.define_singleton_method(:fetch) { |index| index.zero? ? runtime.object_id : generation }
      Fiber[guard_key] = token

      Julewire.emit(message: "foreign-shape-token")

      assert_same token, Fiber[guard_key]
    ensure
      Fiber[guard_key] = nil if defined?(guard_key) && guard_key
    end

    def test_raw_thread_spawned_inside_configure_can_emit_after_configure_finishes
      output = StringIO.new
      release = Queue.new
      result = Queue.new
      thread = nil

      Julewire.configure do |config|
        configure_destination(config, output: output)
        thread = safe_thread do
          release.pop
          Julewire.emit(message: "raw-thread")
          result << :ok
        rescue StandardError => e
          result << e
        end
      end

      release << true
      emitted = safe_queue_pop(result)

      assert_equal :ok, emitted
      assert_equal "raw-thread", JSON.parse(output.string).fetch("message")
    ensure
      release&.push(true)
      safe_thread_value(thread) if thread
      cleanup_thread(thread)
    end
  end
end
