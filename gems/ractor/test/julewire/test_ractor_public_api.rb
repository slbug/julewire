# frozen_string_literal: true

require "test_helper"
require_relative "support/bridge_test_values"

module Julewire
  class TestRactorChildStats < Minitest::Test
    cover "Julewire.ractor"
    cover "Julewire::Ractor.child_stats"
    cover "Julewire::Ractor.child_runtime"
    cover "Julewire::Ractor.reset_child_stats!"

    def test_child_stats_are_visible_inside_julewire_ractor
      with_experimental_ractor_warnings_suppressed do
        output = QueueingOutput.new
        Julewire.configure { configure_direct_destination(it, output: output) }
        stats = with_overridden_singleton_method(Julewire::Ractor::Bridge, :monitor_ractor, proc { |*_arguments| }) do
          Julewire.ractor do
            Julewire.emit(message: "from child")
            Julewire::Ractor.child_stats
          end
        end
        stats = stats.value

        assert_equal "from child", JSON.parse(safe_queue_pop(output)).fetch("message")
        assert_equal 1, stats.dig(:counts, :messages_sent)
        assert_equal 0, stats.dig(:counts, :messages_dropped)
      end
    end

    def test_ractor_wrapper_forwards_args_name_and_context
      with_experimental_ractor_warnings_suppressed do
        Julewire.context.add(request_id: "request-1")
        result = with_overridden_singleton_method(Julewire::Ractor::Bridge, :monitor_ractor, proc { |*_arguments| }) do
          Julewire.ractor("left", "right", name: "julewire-test-worker") do |left, right|
            {
              args: [left, right],
              context: Julewire.context.to_h,
              name: ::Ractor.current.name
            }
          end
        end
        result = result.value

        assert_equal %w[left right], result.fetch(:args)
        assert_equal "julewire-test-worker", result.fetch(:name)
        assert_equal({ request_id: "request-1" }, result.fetch(:context))
      end
    end

    def test_child_stats_are_empty_outside_child_runtime
      assert_empty Julewire::Ractor.child_stats
    end

    def test_reset_child_stats_is_noop_outside_child_runtime
      assert_nil Julewire::Ractor.reset_child_stats!
    end

    def test_child_stats_delegate_to_child_like_runtime
      previous = Julewire::Core::RuntimeLocator.current
      runtime = Object.new
      runtime.define_singleton_method(:child_stats) { { counts: { messages_sent: 2 } } }
      runtime.define_singleton_method(:reset_child_stats!) { :reset }
      Julewire::Core::RuntimeLocator.current = runtime

      assert_equal({ counts: { messages_sent: 2 } }, Julewire::Ractor.child_stats)
      assert_equal :reset, Julewire::Ractor.reset_child_stats!
    ensure
      Julewire::Core::RuntimeLocator.current = previous if previous
    end

    private

    def with_experimental_ractor_warnings_suppressed(&)
      Julewire.enable_experimental_ractor!

      with_overridden_singleton_method(Warning, :warn, proc { |_message| }, &)
    end
  end

  class TestRactorChildFlush < Minitest::Test
    cover "Julewire::Ractor::RemoteRuntime#flush"

    def test_child_emit_and_flush_use_the_real_parent_bridge
      Julewire.enable_experimental_ractor!
      output = QueueingOutput.new
      Julewire.configure { configure_direct_destination(it, output: output) }

      result = with_overridden_singleton_method(Warning, :warn, proc { |_message| }) do
        Julewire.ractor do
          Julewire.emit(message: "flushed from child")
          [Julewire.flush(timeout: 0.5), Julewire::Ractor.child_stats]
        end.value
      end
      flushed, stats = result

      assert_true flushed
      assert_equal "flushed from child", JSON.parse(safe_queue_pop(output)).fetch("message")
      assert_equal 1, stats.dig(:counts, :messages_sent)
      assert_equal 1, stats.dig(:counts, :requests_sent)
      assert_equal 0, stats.dig(:counts, :requests_failed)
      assert_nil stats[:last_error_class]
    end
  end

  class TestRactorPublicHelpers < Minitest::Test
    cover "Julewire.ractor"
    cover "Julewire::Ractor.enable_default_destination_workers!"
    def test_julewire_ractor_requires_a_block_with_clear_error
      error = assert_raises(ArgumentError) { Julewire.ractor }

      assert_equal "block required", error.message
    end

    def test_julewire_ractor_forwards_args_name_runtime_and_block
      calls = []
      runtime = Object.new
      previous = Julewire::Core::RuntimeLocator.current
      Julewire::Core::RuntimeLocator.current = runtime
      replacement = proc do |args:, name:, runtime:, &block|
        calls << [args, name, runtime, block.call(:from_bridge)]
        :started
      end

      result = with_overridden_singleton_method(Julewire::Ractor::Bridge, :start, replacement) do
        Julewire.ractor(:first, :second, name: :worker) { |value| [:block, value] }
      end

      assert_equal :started, result
      assert_equal [[%i[first second], :worker, runtime, %i[block from_bridge]]], calls
    ensure
      Julewire::Core::RuntimeLocator.current = previous if previous
    end

    def test_enable_default_destination_workers_registers_default_ractor_factory
      port = ::Ractor::Port.new
      destination = nil

      assert_nil Julewire::Ractor.enable_default_destination_workers!

      factory = Julewire::Core::Destinations.factory_for(:default)
      destination = factory.call(name: :worker, output: RactorPortOutput.new(port))

      assert_instance_of Julewire::Ractor::Destination, destination
      assert_equal :worker, destination.name
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end
  end

  class TestRactorDefaultDestinationFactory < Minitest::Test
    cover "Julewire::Ractor.enable_default_destination_workers!"
    def test_default_destination_kind_uses_ractor_worker
      port = ::Ractor::Port.new
      Julewire::Ractor.enable_default_destination_workers!

      Julewire.configure do |config|
        config.destinations.use(:default, output: RactorPortOutput.new(port))
      end

      safe_thread_value(safe_thread { Julewire.emit(message: "default-worker") }, timeout: 0.1)

      assert_true Julewire.flush(timeout: 0.1)
      assert_equal "default-worker", JSON.parse(receive_ractor(port)).fetch("message")
      assert_equal :ok, Julewire.health.dig(:pipeline, :destinations, :default, :status)
    ensure
      bounded_ractor_operation { Julewire.close(timeout: 0.1) }
      Julewire::Ractor::PortLifecycle.close(port) if port
    end
  end

  class TestRactorRegisteredDestinationFactory < Minitest::Test
    cover Julewire::Ractor::Destination

    def test_ractor_destination_kind_uses_ractor_worker
      port = ::Ractor::Port.new

      Julewire.configure do |config|
        config.destinations.use(:ractor, output: RactorPortOutput.new(port))
      end

      safe_thread_value(safe_thread { Julewire.emit(message: "registered-worker") }, timeout: 0.1)

      assert_true Julewire.flush(timeout: 0.1)
      assert_equal "registered-worker", JSON.parse(receive_ractor(port)).fetch("message")
      assert_equal :ok, Julewire.health.dig(:pipeline, :destinations, :ractor, :status)
    ensure
      bounded_ractor_operation { Julewire.close(timeout: 0.1) }
      Julewire::Ractor::PortLifecycle.close(port) if port
    end
  end
end
