# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRactorWorkerHandshake < Minitest::Test
    cover "Julewire::Ractor::WorkerHandshake.receive"

    def test_returns_the_worker_command_port
      with_waiting_worker do |setup_port, worker|
        worker_port = ::Ractor::Port.new
        setup_port.send(worker_port)

        assert_same worker_port, receive_handshake(setup_port, worker)
      ensure
        Julewire::Ractor::PortLifecycle.close(worker_port) if worker_port
      end
    end

    def test_accepts_a_ractor_port_subclass_from_the_setup_port
      with_waiting_worker do |setup_port, worker|
        worker_port = Class.new(::Ractor::Port).new
        setup_port.send(worker_port)

        assert_same worker_port, receive_handshake(setup_port, worker)
      ensure
        Julewire::Ractor::PortLifecycle.close(worker_port) if worker_port
      end
    end

    def test_raises_after_the_start_timeout
      with_waiting_worker do |setup_port, worker|
        error = assert_raises(Julewire::Core::Error) do
          receive_handshake(setup_port, worker, timeout: 0)
        end

        assert_equal "ractor destination worker did not start within 0 seconds", error.message
      end
    end

    def test_default_start_timeout_is_bounded
      with_waiting_worker do |setup_port, worker|
        error = with_temporary_constant(worker_handshake, :DEFAULT_TIMEOUT, 0) do
          assert_raises(Julewire::Core::Error) do
            safe_thread_value(
              safe_thread do
                worker_handshake.receive(
                  setup_port: setup_port,
                  worker: worker,
                  scheduler: Julewire::Ractor::ReplyTimeoutScheduler.new(timeout_value: false)
                )
              end,
              timeout: 0.1
            )
          end
        end

        assert_equal "ractor destination worker did not start within 0 seconds", error.message
      end
    end

    def test_rejects_a_non_port_setup_value
      with_waiting_worker do |setup_port, worker|
        setup_port.send(:not_a_port)

        error = assert_raises(ArgumentError) { receive_handshake(setup_port, worker) }

        assert_equal "ractor destination worker did not start", error.message
      end
    end

    def test_rejects_a_worker_that_exits_before_the_handshake
      setup_port = ::Ractor::Port.new
      worker = ::Ractor.new { :exited }

      error = assert_raises(ArgumentError) { receive_handshake(setup_port, worker) }

      assert_equal "ractor destination worker did not start", error.message
    ensure
      Julewire::Ractor::PortLifecycle.close(setup_port) if setup_port
      wait_for_ractor_cleanup(worker) if worker
    end

    def test_rejects_a_port_returned_by_a_worker_that_exits_before_the_handshake
      setup_port = ::Ractor::Port.new
      returned_port = ::Ractor::Port.new
      worker = ::Ractor.new(returned_port) { it }

      error = assert_raises(ArgumentError) { receive_handshake(setup_port, worker) }

      assert_equal "ractor destination worker did not start", error.message
    ensure
      Julewire::Ractor::PortLifecycle.close(setup_port) if setup_port
      Julewire::Ractor::PortLifecycle.close(returned_port) if returned_port
      wait_for_ractor_cleanup(worker) if worker
    end

    private

    def receive_handshake(setup_port, worker, timeout: 0.25)
      safe_thread_value(
        safe_thread do
          worker_handshake.receive(
            setup_port: setup_port,
            worker: worker,
            scheduler: Julewire::Ractor::ReplyTimeoutScheduler.new(timeout_value: false),
            timeout: timeout
          )
        end,
        timeout: 0.1
      )
    end

    def with_waiting_worker
      setup_port = ::Ractor::Port.new
      bootstrap_port = ::Ractor::Port.new
      worker = ::Ractor.new(bootstrap_port) do |parent_port|
        worker_port = ::Ractor::Port.new
        parent_port.send(worker_port)
        worker_port.receive
      end
      release_port = bootstrap_port.receive
      yield setup_port, worker
    ensure
      release_port&.send(:done)
      wait_for_ractor_cleanup(worker) if worker
      Julewire::Ractor::PortLifecycle.close(setup_port) if setup_port
      Julewire::Ractor::PortLifecycle.close(bootstrap_port) if bootstrap_port
      Julewire::Ractor::PortLifecycle.close(release_port) if release_port
    end

    def worker_handshake
      Julewire::Ractor.const_get(:WorkerHandshake, false)
    end
  end
end
