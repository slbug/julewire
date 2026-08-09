# frozen_string_literal: true

require "test_helper"
require_relative "support/bridge_test_values"

module Julewire
  class TestRactorDestination < Minitest::Test
    cover "Julewire::Ractor::Destination#enqueue"
    cover "Julewire::Ractor::Destination#health"
    cover "Julewire::Ractor::Destination#handle_ack"
    cover "Julewire::Ractor::Destination#initialize"
    cover "Julewire::Ractor::Destination#initialize_tracking"
    cover "Julewire::Ractor::Destination#spawn_worker"
    cover "Julewire::Ractor::Destination#start_worker"
    cover "Julewire::Ractor::Destination#status_for"
    cover "Julewire::Ractor::Destination#validate_callable"
    include DroppingRactorDestinationHelper
    include RactorRecordHelper
    include RactorWaitHelper

    class MutableCopyabilityOutput < RactorPortOutput
      def make_non_copyable!
        @non_copyable = proc {}
      end
    end

    def test_ractor_destination_reports_worker_drops
      write_port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(
        output: RejectingRactorPortOutput.new(write_port),
        request_timeout: 0.1
      )

      safe_thread_value(safe_thread { destination.emit(record(message: "rejected")) }, timeout: 0.1)

      assert_equal "rejected", JSON.parse(receive_ractor(write_port)).fetch("message")
      assert_true destination.flush(timeout: 0.1)
      wait_until { destination.health.dig(:counts, :worker_dropped) == 1 }
      health = destination.health

      assert_equal 1, health.dig(:counts, :worker_dropped)
      assert_equal :ok, health.fetch(:status)
      assert_equal :output_rejected, health.dig(:worker, :last_loss, :reason)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(write_port) if write_port
    end

    def test_ractor_destination_uses_default_lifecycle_timeout
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(output: RactorPortOutput.new(port))

      safe_thread_value(safe_thread { destination.emit(record(message: "default-timeout")) }, timeout: 0.1)

      assert_true safe_thread_value(safe_thread { destination.flush }, timeout: 0.1)
      assert_equal "default-timeout", JSON.parse(receive_ractor(port)).fetch("message")
      assert_true(bounded_ractor_operation { destination.close })
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_uses_the_default_request_timeout
      port = ::Ractor::Port.new
      destination = nil
      with_temporary_constant(Julewire::Ractor::Destination, :DEFAULT_REQUEST_TIMEOUT, 0.01) do
        destination = Julewire::Ractor::Destination.new(
          output: SlowFlushRactorPortOutput.new(port, sleep_seconds: 0.05)
        )

        assert_false destination.flush
        assert_equal :flushing, receive_ractor(port)
      end
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_explicit_nil_uses_configured_lifecycle_timeout
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(
        output: SlowFlushRactorPortOutput.new(port, sleep_seconds: 0.05),
        request_timeout: 0.01
      )

      assert_false destination.flush(timeout: nil)
      assert_equal :flushing, receive_ractor(port)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_defaults_name_and_queue
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(output: RactorPortOutput.new(port))

      assert_equal :ractor, destination.name
      assert_equal Julewire::Ractor::Destination::DEFAULT_MAX_QUEUE, destination.health.fetch(:max_queue)
      assert_equal :ok, destination.health.fetch(:status)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_names_worker_ractor
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(output: RactorPortOutput.new(port))

      assert_equal "julewire-ractor-destination", destination.instance_variable_get(:@worker).name
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_normalizes_name
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(output: RactorPortOutput.new(port), name: "worker")

      assert_equal :worker, destination.name
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_defaults_use_top_level_julewire_formatter_and_encoder
      port = ::Ractor::Port.new
      destination = nil
      shadow_formatter = Class.new { def self.new = raise("shadow formatter used") }
      shadow_encoder = Class.new { def self.new = raise("shadow encoder used") }

      with_temporary_constant(Julewire::Ractor, :RecordFormatter, shadow_formatter) do
        with_temporary_constant(Julewire::Ractor, :JsonEncoder, shadow_encoder) do
          destination = Julewire::Ractor::Destination.new(output: RactorPortOutput.new(port))
          safe_thread_value(safe_thread { destination.emit(record(message: "shadow-safe")) }, timeout: 0.1)

          assert_true destination.flush(timeout: 0.1)
          assert_equal "shadow-safe", JSON.parse(receive_ractor(port)).fetch("message")
        end
      end
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_validates_constructor_options
      cases = [
        [:output, { output: Object.new }, "output must respond to #write"],
        [:formatter, { formatter: Object.new }, "formatter must respond to #call"],
        [:encoder, { encoder: Object.new }, "encoder must respond to #call"],
        [:max_record_bytes, { max_record_bytes: 0 }, "max_record_bytes must be nil or a positive Integer"],
        [:max_queue, { max_queue: -1 }, "max_queue must be a non-negative Integer"],
        [
          :request_timeout,
          { request_timeout: -1 },
          "request_timeout must be nil or a non-negative finite Numeric"
        ],
        [:request_timeout, { request_timeout: nil }, "request_timeout must be a non-negative finite Numeric"],
        [:on_drop, { on_drop: Object.new }, "on_drop must respond to #call"],
        [:on_failure, { on_failure: Object.new }, "on_failure must respond to #call"]
      ]

      cases.each do |option, overrides, message|
        port = ::Ractor::Port.new
        destination = nil
        begin
          error = assert_raises(ArgumentError) do
            destination = Julewire::Ractor::Destination.new(output: RactorPortOutput.new(port), **overrides)
          end

          assert_equal message, error.message, option
        ensure
          cleanup_ractor_destination(destination)
          Julewire::Ractor::PortLifecycle.close(port)
        end
      end
    end

    def test_ractor_destination_default_record_byte_limit_drops_oversized_records
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(
        output: RactorPortOutput.new(port),
        encoder: StaticEncoder.new("x" * (Julewire::Core::DEFAULT_MAX_RECORD_BYTES + 1))
      )

      safe_thread_value(safe_thread { destination.emit(record(message: "oversized")) }, timeout: 0.1)

      assert_true destination.flush(timeout: 0.1)
      wait_until { destination.health.dig(:counts, :worker_dropped) == 1 }
      health = destination.health

      assert_equal 1, health.dig(:counts, :worker_dropped)
      assert_equal :record_too_large, health.dig(:worker, :last_loss, :reason)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_explicit_record_byte_limit_drops_oversized_records
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(
        output: RactorPortOutput.new(port),
        encoder: StaticEncoder.new("too large"),
        max_record_bytes: 1
      )

      safe_thread_value(safe_thread { destination.emit(record(message: "oversized")) }, timeout: 0.1)

      assert_true destination.flush(timeout: 0.1)
      wait_until { destination.health.dig(:counts, :worker_dropped) == 1 }
      health = destination.health

      assert_equal 1, health.dig(:counts, :worker_dropped)
      assert_equal :record_too_large, health.dig(:worker, :last_loss, :reason)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end
  end

  class TestRactorDestinationLifecycleOptions < Minitest::Test
    cover "Julewire::Ractor::Destination#close"
    cover "Julewire::Ractor::Destination#flush"
    cover "Julewire::Ractor::Destination#initialize"
    cover "Julewire::Ractor::Destination#lifecycle_timeout"
    cover "Julewire::Ractor::Destination#request"
    cover "Julewire::Ractor::Destination#spawn_worker"
    cover "Julewire::Ractor::Destination#wait_for_reply"
    include DroppingRactorDestinationHelper
    include RactorRecordHelper
    include RactorWaitHelper

    def test_ractor_destination_closes_owned_output
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(output: RactorPortOutput.new(port), close_output: true)

      assert_true(bounded_ractor_operation { destination.close(timeout: 0.1) })

      assert_equal :closed, receive_ractor(port)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_does_not_close_borrowed_output_by_default
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(output: RactorPortOutput.new(port))

      assert_true(bounded_ractor_operation { destination.close(timeout: 0.1) })
      assert_equal :flushed, receive_ractor(port)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_returns_rejected_owned_output_close
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(
        output: RejectingCloseRactorPortOutput.new(port),
        close_output: true,
        request_timeout: 0.75
      )

      assert_false(bounded_ractor_operation { destination.close(timeout: 0.25) })

      assert_equal :close_rejected, receive_ractor(port)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_close_uses_configured_default_timeout
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(
        output: SlowFlushRactorPortOutput.new(port),
        request_timeout: 0.01
      )

      assert_false(bounded_ractor_operation { destination.close })
      assert_equal :flushing, receive_ractor(port)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_close_preserves_explicit_timeout
      assert_explicit_lifecycle_timeout_is_preserved(:close)
    end

    def test_ractor_destination_flush_uses_configured_default_timeout
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(
        output: SlowFlushRactorPortOutput.new(port, sleep_seconds: 0.05),
        request_timeout: 0.01
      )

      assert_false(bounded_ractor_operation { destination.flush })
      assert_equal :flushing, receive_ractor(port)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_flush_preserves_explicit_timeout
      assert_explicit_lifecycle_timeout_is_preserved(:flush)
    end

    def test_ractor_destination_rejects_invalid_lifecycle_timeouts_before_ipc
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(output: RactorPortOutput.new(port))

      error = assert_raises(ArgumentError) { destination.flush(timeout: -1) }

      assert_equal "timeout must be nil or a non-negative finite Numeric", error.message
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    private

    def assert_explicit_lifecycle_timeout_is_preserved(command)
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(
        output: SlowFlushRactorPortOutput.new(port, sleep_seconds: 0.05),
        request_timeout: 0.01
      )

      assert_true(bounded_ractor_operation { destination.public_send(command, timeout: 0.25) })
      assert_equal :flushing, receive_ractor(port)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end
  end

  class TestRactorDestinationIdentity < Minitest::Test
    cover "Julewire::Ractor::Destination#resource_identity"

    def test_ractor_destination_resource_identity_is_the_destination
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(output: RactorPortOutput.new(port))

      assert_same destination, destination.resource_identity
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end
  end

  class TestRactorDestinationRequest < Minitest::Test
    cover "Julewire::Ractor::Destination#request"
    cover "Julewire::Ractor::Destination#wait_for_reply"

    class ExitingFlushOutput
      def initialize(entered_port)
        @entered_port = entered_port
      end

      def write(_value) = true # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy write results.

      def flush
        @entered_port.send(:flushing)
        ::Ractor.receive
        Thread.exit
      end
    end

    class AbortingFlushOutput
      def initialize(entered_port)
        @entered_port = entered_port
      end

      def write(_value) = true # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy write results.

      def flush
        @entered_port.send(:flushing)
        ::Ractor.receive
        raise SystemExit, "output terminated worker"
      end
    end

    def test_ractor_destination_request_reports_send_failures
      port = ::Ractor::Port.new
      failures = Queue.new
      destination = Julewire::Ractor::Destination.new(
        output: RactorPortOutput.new(port),
        on_failure: ->(error, metadata) { failures << [error.class, metadata] }
      )
      destination.instance_variable_get(:@port).send({ command: :close_worker })
      destination.instance_variable_get(:@worker).value

      result = bounded_ractor_operation { destination.flush(timeout: nil) }

      assert_false result
      failure_class, metadata = safe_queue_pop(failures, timeout: 0.1)

      assert_equal ::Ractor::ClosedError, failure_class
      assert_equal :request, metadata.fetch(:phase)
      assert_equal :flush, metadata.fetch(:command)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_request_returns_when_worker_exits_before_reply
      previous_report_on_exception = Thread.report_on_exception
      Thread.report_on_exception = false
      entered_port = ::Ractor::Port.new
      failures = Queue.new
      destination = Julewire::Ractor::Destination.new(
        output: ExitingFlushOutput.new(entered_port),
        on_failure: ->(error, metadata) { failures << [error, metadata] }
      )
      worker = destination.instance_variable_get(:@worker)
      flush_thread = safe_thread { destination.flush(timeout: 0.1) }

      assert_equal :flushing, receive_ractor(entered_port)
      worker.send(:exit)

      assert_false safe_thread_value(flush_thread)
      error, metadata = safe_queue_pop(failures, timeout: 0.1)

      assert_instance_of Julewire::Core::Error, error
      assert_equal "ractor destination worker stopped before flush replied", error.message
      assert_nil error.cause
      assert_equal :request, metadata.fetch(:phase)
      assert_equal :flush, metadata.fetch(:command)
    ensure
      Thread.report_on_exception = previous_report_on_exception if defined?(previous_report_on_exception)
      cleanup_thread(flush_thread) if defined?(flush_thread)
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(entered_port) if entered_port
    end

    def test_ractor_destination_request_translates_abnormal_worker_exit
      previous_report_on_exception = Thread.report_on_exception
      Thread.report_on_exception = false
      entered_port = ::Ractor::Port.new
      failures = Queue.new
      destination = Julewire::Ractor::Destination.new(
        output: AbortingFlushOutput.new(entered_port),
        on_failure: ->(error, metadata) { failures << [error, metadata] }
      )
      worker = destination.instance_variable_get(:@worker)
      flush_thread = safe_thread { destination.flush(timeout: 0.1) }

      assert_equal :flushing, receive_ractor(entered_port)
      worker.send(:exit)

      assert_false safe_thread_value(flush_thread)
      error, metadata = safe_queue_pop(failures, timeout: 0.1)

      assert_instance_of Julewire::Core::Error, error
      assert_equal "ractor destination worker stopped before flush replied", error.message
      assert_instance_of ::Ractor::RemoteError, error.cause
      assert_equal :request, metadata.fetch(:phase)
      assert_equal :flush, metadata.fetch(:command)
    ensure
      Thread.report_on_exception = previous_report_on_exception if defined?(previous_report_on_exception)
      cleanup_thread(flush_thread) if defined?(flush_thread)
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(entered_port) if entered_port
    end
  end

  class TestRactorDestinationHealth < Minitest::Test
    cover "Julewire::Ractor::Destination#closed?"
    cover "Julewire::Ractor::Destination#health"
    cover "Julewire::Ractor::Destination#request"
    cover "Julewire::Ractor::Destination#status_for"
    cover "Julewire::Ractor::Destination#wait_for_reply"
    include RactorRecordHelper

    class RecoveringFlushOutput
      def initialize
        @flush_failed = false
      end

      def write(_value) = true # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy write results.

      def flush # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy flush results.
        unless @flush_failed
          @flush_failed = true
          raise "flush failed"
        end

        true
      end

      def closed? = false
      def close = true # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy close results.
    end
    private_constant :RecoveringFlushOutput

    def test_ractor_destination_health_keeps_the_last_worker_snapshot_after_close
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(output: RactorPortOutput.new(port))
      cached = bounded_ractor_operation { destination.health }.fetch(:worker)

      assert_true(bounded_ractor_operation { destination.close(timeout: 0.1) })

      health = destination.health

      assert_equal cached, health.fetch(:worker)
      assert_equal :closed, health.fetch(:status)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_health_rejects_malformed_worker_protocol
      invalid_replies = {
        Class.new(Hash).new.merge(status: :ok) => "ractor destination health must be a Hash",
        { "status" => :ok } => Julewire::Core::Fields::Internal::RECORD_STRING_KEY_ERROR,
        not_worker_health: "ractor destination health must be a Hash"
      }

      invalid_replies.each do |reply, expected_message|
        port = ::Ractor::Port.new
        destination = Julewire::Ractor::Destination.new(output: RactorPortOutput.new(port))
        destination.instance_variable_get(:@port).send({ command: :close_worker })
        destination.instance_variable_get(:@worker).value
        destination.instance_variable_set(:@port, ReplyingPort.new(reply: reply))

        error = assert_raises(TypeError) { destination.health }

        assert_equal expected_message, error.message
      ensure
        cleanup_ractor_destination(destination)
        Julewire::Ractor::PortLifecycle.close(port) if port
      end
    end

    def test_ractor_destination_health_uses_the_configured_request_timeout
      output_port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(
        output: SlowRactorPortOutput.new(output_port, sleep_seconds: 0.05),
        request_timeout: 0.01
      )
      destination.emit(record(message: "busy"))

      assert_equal "busy", JSON.parse(receive_ractor(output_port)).fetch("message")

      health = Timeout.timeout(0.1) { destination.health }

      assert_false health.key?(:worker)
      assert_equal :ok, health.fetch(:status)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(output_port) if output_port
    end

    def test_ractor_destination_health_reflects_worker_degradation_and_recovery
      destination = Julewire::Ractor::Destination.new(output: RecoveringFlushOutput.new)

      assert_false(bounded_ractor_operation { destination.flush(timeout: 0.1) })

      health = bounded_ractor_operation { destination.health }

      assert_equal :degraded, health.dig(:worker, :status)
      assert_equal :degraded, health.fetch(:status)
      assert_false health.key?(:last_failure)
      assert_false health.key?(:last_loss)

      assert_true(bounded_ractor_operation { destination.flush(timeout: 0.1) })

      recovered = bounded_ractor_operation { destination.health }

      assert_equal :ok, recovered.dig(:worker, :status)
      assert_equal :ok, recovered.fetch(:status)
      assert_equal :output_lifecycle, recovered.dig(:worker, :last_failure, :phase)
      assert_equal :flush, recovered.dig(:worker, :last_failure, :action)
      assert_equal "RuntimeError", recovered.dig(:worker, :last_failure, :class)
    ensure
      cleanup_ractor_destination(destination)
    end

    def test_ractor_destination_rejects_lifecycle_requests_after_close
      port = ::Ractor::Port.new
      failures = Queue.new
      destination = Julewire::Ractor::Destination.new(
        output: RactorPortOutput.new(port),
        on_failure: ->(error, metadata) { failures << [error, metadata] }
      )

      assert_true(bounded_ractor_operation { destination.close(timeout: 0.1) })
      assert_false destination.flush(timeout: 0.1)
      assert_equal :closed, destination.health.fetch(:status)
      assert_empty nonblocking_queue_values(failures)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end
  end

  class TestRactorDestinationShutdown < Minitest::Test
    cover "Julewire::Ractor::Destination#close"
    cover "Julewire::Ractor::Destination#close_ports"
    cover "Julewire::Ractor::Destination#wait_for_worker"
    include RactorRecordHelper
    include RactorWaitHelper

    def test_ractor_destination_close_releases_owned_ports_and_ack_thread
      port = ::Ractor::Port.new
      failures = Queue.new
      destination = Julewire::Ractor::Destination.new(
        output: RactorPortOutput.new(port),
        on_failure: ->(error, metadata) { failures << [error, metadata] }
      )
      command_port = destination.instance_variable_get(:@port)
      ack_port = destination.instance_variable_get(:@ack_port)
      ack_thread = destination.instance_variable_get(:@ack_thread)
      destination.emit(record(message: "ack-thread-active"))

      assert_equal "ack-thread-active", JSON.parse(receive_ractor(port)).fetch("message")
      wait_until { destination.health.dig(:counts, :worker_accepted) == 1 }
      wait_until { ack_thread.status == "sleep" }

      assert_true(bounded_ractor_operation { destination.close(timeout: 0.1) })

      assert_predicate command_port, :closed?
      refute_predicate ack_thread, :alive?
      assert_predicate ack_port, :closed?
      assert_nil destination.instance_variable_get(:@port)
      assert_nil destination.instance_variable_get(:@worker)
      assert_nil destination.instance_variable_get(:@ack_port)
      assert_nil destination.instance_variable_get(:@ack_thread)
      assert_empty nonblocking_queue_values(failures)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_close_is_idempotent_after_worker_collection
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(output: RactorPortOutput.new(port))

      assert_true(bounded_ractor_operation { destination.close(timeout: 0.1) })
      assert_true(bounded_ractor_operation { destination.close(timeout: 0.1) })

      assert_nil destination.instance_variable_get(:@port)
      assert_nil destination.instance_variable_get(:@worker)
      assert_nil destination.instance_variable_get(:@ack_port)
      assert_nil destination.instance_variable_get(:@ack_thread)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end
  end

  class TestRactorDestinationForkLifecycle < Minitest::Test
    cover "Julewire::Ractor::Destination#initialize"
    cover "Julewire::Ractor::Destination#before_fork!"
    cover "Julewire::Ractor::Destination#enqueue"
    cover "Julewire::Ractor::Destination#after_fork!"
    cover "Julewire::Ractor::Destination#close_ports"
    cover "Julewire::Ractor::Destination#initialize_tracking"
    cover "Julewire::Ractor::Destination#spawn_worker"
    cover "Julewire::Ractor::Destination#start_worker"
    cover "Julewire::Ractor::Destination#wait_for_worker"
    cover "Julewire::Ractor::Destination#flush_before_fork!"
    cover "Julewire::Ractor::Destination#stop_before_fork!"
    cover "Julewire::Ractor::Destination#validate_after_fork_process!"
    cover "Julewire::Ractor::Destination#validate_before_fork_process!"
    include DroppingRactorDestinationHelper
    include RactorRecordHelper
    include RactorWaitHelper

    class ForkPipeOutput
      def initialize(io)
        @io = io
      end

      def write(value) # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy write results.
        @io.puts(value)
        @io.flush
        true
      end

      def flush # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy flush results.
        @io.flush
        true
      end
    end

    def test_ractor_destination_after_fork_is_idempotent_without_preparation
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(
        output: RactorPortOutput.new(port),
        request_timeout: 0.1
      )
      old_command_port = destination.instance_variable_get(:@port)
      old_worker = destination.instance_variable_get(:@worker)
      old_ack_port = destination.instance_variable_get(:@ack_port)
      old_ack_thread = destination.instance_variable_get(:@ack_thread)

      assert_same destination, destination.after_fork!
      assert_same old_command_port, destination.instance_variable_get(:@port)
      assert_same old_worker, destination.instance_variable_get(:@worker)
      assert_same old_ack_port, destination.instance_variable_get(:@ack_port)
      assert_same old_ack_thread, destination.instance_variable_get(:@ack_thread)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_restarts_and_emits_in_a_forked_process
      require_process_fork!

      reader, writer = IO.pipe
      status_reader, status_writer = IO.pipe
      destination = Julewire::Ractor::Destination.new(
        output: ForkPipeOutput.new(writer),
        request_timeout: 1
      )
      Julewire.configure { it.destinations.add(destination) }

      assert_nil Julewire.before_fork!(timeout: 1)
      assert_nil destination.instance_variable_get(:@port)
      assert_nil destination.instance_variable_get(:@worker)

      child_pid = Process.fork do
        reader.close
        status_reader.close
        exit_status = 1
        begin
          Julewire.after_fork!
          Julewire.emit(message: "fork-child")
          flushed = Julewire.flush(timeout: 1)
          status_writer.puts("flush_result:#{flushed}")
          status_writer.flush
          exit_status = 0 if flushed
        ensure
          cleanup_ractor_destination(destination)
        end
        exit! exit_status
      end
      writer.close
      status_writer.close

      assert reader.wait_readable(2), "forked destination did not emit"
      emitted = JSON.parse(reader.gets)

      assert status_reader.wait_readable(2), "forked destination did not flush"
      flush_result = status_reader.gets.chomp

      _pid, status = Timeout.timeout(2) { Process.wait2(child_pid) }
      child_pid = nil
      Julewire.after_fork!

      assert_equal "fork-child", emitted.fetch("message")
      assert_equal "flush_result:true", flush_result
      assert_predicate status, :success?
    ensure
      if child_pid
        begin
          Process.kill(:KILL, child_pid)
        rescue Errno::ESRCH
          nil
        end
        begin
          Process.wait(child_pid)
        rescue Errno::ECHILD
          nil
        end
      end
      cleanup_ractor_destination(destination)
      reader&.close
      writer&.close unless writer&.closed?
      status_reader&.close unless status_reader&.closed?
      status_writer&.close unless status_writer&.closed?
    end

    def test_ractor_destination_rejects_an_unprepared_inherited_restart
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(output: RactorPortOutput.new(port))
      old_process_id = destination.instance_variable_get(:@process_id)
      worker = destination.instance_variable_get(:@worker)
      destination.instance_variable_set(:@process_id, old_process_id - 1)

      before_error = assert_raises(Julewire::Core::UnsafeForkError) { destination.before_fork! }
      before_health = destination.health
      after_error = assert_raises(Julewire::Core::UnsafeForkError) { destination.after_fork! }
      after_health = destination.health

      assert_match "without Julewire.before_fork!", before_error.message
      assert_equal before_error.message, after_error.message
      assert_equal :before_fork, before_health.dig(:last_failure, :phase)
      assert_equal "Julewire::Core::UnsafeForkError", before_health.dig(:last_failure, :class)
      assert_equal :after_fork, after_health.dig(:last_failure, :phase)
      assert_equal "Julewire::Core::UnsafeForkError", after_health.dig(:last_failure, :class)
      assert_same worker, destination.instance_variable_get(:@worker)
    ensure
      destination.instance_variable_set(:@process_id, old_process_id) if destination && old_process_id
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_rejects_emits_while_quiesced
      port, drops, destination = dropping_ractor_destination

      assert_same destination, destination.before_fork!(timeout: 0.1)
      assert_same destination, destination.before_fork!(timeout: 0.1)
      assert_equal :flushed, receive_ractor(port)

      destination.emit(record(message: "between-fork-hooks"))

      assert_equal :closed_dropped, safe_queue_pop(drops)
      assert_equal 1, destination.health.dig(:counts, :closed_dropped)

      assert_same destination, destination.after_fork!
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_before_fork_accepts_configured_default_timeout
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(
        output: RactorPortOutput.new(port),
        request_timeout: 0.1
      )

      assert_same destination, destination.before_fork!
      assert_equal :flushed, receive_ractor(port)
      assert_same destination, destination.after_fork!
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    private

    def require_process_fork!
      skip "Process.fork is unavailable" unless Process.respond_to?(:fork)
    end

    public

    def test_ractor_destination_before_fork_uses_configured_flush_bound
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(
        output: SlowFlushRactorPortOutput.new(port, sleep_seconds: 0.05),
        request_timeout: 0.01
      )

      error = assert_raises(Julewire::Core::Error) { destination.before_fork! }

      assert_equal "ractor destination could not flush before fork", error.message
      assert_equal :flushing, receive_ractor(port)
      assert_equal :before_fork, destination.health.dig(:last_failure, :phase)
      assert_equal "Julewire::Core::Error", destination.health.dig(:last_failure, :class)

      assert_nil destination.emit(record(message: "usable-after-failed-preparation"))
      assert_true destination.flush(timeout: 0.2)
      assert_equal :flushing, receive_ractor(port)

      health = destination.health

      assert_equal 1, health.dig(:counts, :received)
      assert_equal 1, health.dig(:counts, :queued)
      assert_equal 0, health.dig(:counts, :closed_dropped)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_before_fork_preserves_explicit_timeout
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(
        output: SlowFlushRactorPortOutput.new(port, sleep_seconds: 0.05),
        request_timeout: 1
      )

      error = assert_raises(Julewire::Core::Error) { destination.before_fork!(timeout: 0.01) }

      assert_equal "ractor destination could not flush before fork", error.message
      assert_equal :flushing, receive_ractor(port)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_before_fork_excludes_concurrent_emit
      port = ::Ractor::Port.new
      drops = Queue.new
      destination = Julewire::Ractor::Destination.new(
        output: SlowFlushRactorPortOutput.new(port, sleep_seconds: 0.1),
        request_timeout: 1,
        on_drop: ->(reason, _metadata) { drops << reason }
      )
      preparing = safe_thread { destination.before_fork!(timeout: 1) }

      assert_equal :flushing, receive_ractor(port)

      emitter = safe_thread { destination.emit(record(message: "during-preparation")) }

      refute emitter.join(0.02), "emit crossed an active before-fork transition"
      assert_same destination, safe_thread_value(preparing)
      assert_nil safe_thread_value(emitter)
      assert_equal :closed_dropped, safe_queue_pop(drops)

      assert_same destination, destination.after_fork!
    ensure
      cleanup_thread(preparing) if preparing&.alive?
      cleanup_thread(emitter) if emitter&.alive?
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_before_fork_does_not_close_owned_output
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(
        output: RactorPortOutput.new(port),
        close_output: true,
        request_timeout: 0.1
      )

      assert_same destination, destination.before_fork!(timeout: 0.1)
      assert_equal :flushed, receive_ractor(port)
      assert_raises(Timeout::Error) { Timeout.timeout(0.02) { ::Ractor.select(port) } }
      assert_same destination, destination.after_fork!
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end
  end

  class TestRactorDestinationTimedShutdown < Minitest::Test
    cover "Julewire::Ractor::Destination#close"
    cover "Julewire::Ractor::Destination#close_ports"
    cover "Julewire::Ractor::Destination#enqueue"
    cover "Julewire::Ractor::Destination#wait_for_worker"
    include RactorWaitHelper
    include RactorRecordHelper

    def test_ractor_destination_close_bounds_worker_teardown
      entered_port = ::Ractor::Port.new
      release_reader, release_writer = IO.pipe
      failures = Queue.new
      destination = Julewire::Ractor::Destination.new(
        output: BlockingCloseOutput.new(entered_port, release_reader),
        close_output: true,
        on_failure: ->(error, metadata) { failures << [error, metadata] }
      )

      assert_false(bounded_ractor_operation { destination.close(timeout: 0.01) })

      assert_equal :closing, receive_ractor(entered_port)
      assert_equal :closed, destination.health.fetch(:status)
      observed = nonblocking_queue_values(failures)
      worker_stop = observed.find { |_error, metadata| metadata.fetch(:phase) == :worker_stop }

      refute_nil worker_stop
      assert_equal "ractor destination worker did not stop within 0.01 seconds", worker_stop.fetch(0).message

      release_writer.puts(:release)
      release_writer.flush

      assert_false(bounded_ractor_operation { destination.close(timeout: 0.1) })
      assert_nil destination.instance_variable_get(:@port)
      assert_nil destination.instance_variable_get(:@worker)
      assert_true(bounded_ractor_operation { destination.close(timeout: 0.1) })
    ensure
      release_writer&.close unless release_writer&.closed?
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(entered_port) if entered_port
      release_reader&.close unless release_reader&.closed?
    end

    def test_ractor_destination_close_excludes_concurrent_emit
      entered_port = ::Ractor::Port.new
      release_reader, release_writer = IO.pipe
      drops = Queue.new
      destination = Julewire::Ractor::Destination.new(
        output: BlockingCloseOutput.new(entered_port, release_reader),
        close_output: true,
        request_timeout: 1,
        on_drop: ->(reason, _metadata) { drops << reason }
      )
      closer = safe_thread { destination.close(timeout: 1) }

      assert_equal :closing, receive_ractor(entered_port)

      emitter = safe_thread { destination.emit(record(message: "during-close")) }

      refute emitter.join(0.02), "emit crossed an active close transition"

      release_writer.puts(:release)
      release_writer.flush

      assert_true safe_thread_value(closer)
      assert_nil safe_thread_value(emitter)
      assert_equal :closed_dropped, safe_queue_pop(drops)
    ensure
      release_writer&.puts(:release) unless release_writer&.closed?
      release_writer&.close unless release_writer&.closed?
      cleanup_thread(closer) if closer&.alive?
      cleanup_thread(emitter) if emitter&.alive?
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(entered_port) if entered_port
      release_reader&.close unless release_reader&.closed?
    end

    def test_ractor_destination_after_fork_does_not_replace_a_worker_retained_after_timed_close
      entered_port = ::Ractor::Port.new
      release_reader, release_writer = IO.pipe
      destination = Julewire::Ractor::Destination.new(
        output: BlockingCloseOutput.new(entered_port, release_reader),
        close_output: true,
        request_timeout: 1
      )
      command_port = destination.instance_variable_get(:@port)
      worker = destination.instance_variable_get(:@worker)

      assert_false(bounded_ractor_operation { destination.close(timeout: 0.01) })
      assert_equal :closing, receive_ractor(entered_port)
      assert_same command_port, destination.instance_variable_get(:@port)
      assert_same worker, destination.instance_variable_get(:@worker)
      refute_predicate command_port, :closed?

      release_writer.puts(:release)
      release_writer.flush

      assert_same(destination, bounded_ractor_operation { destination.after_fork! })
      assert_same command_port, destination.instance_variable_get(:@port)
      assert_same worker, destination.instance_variable_get(:@worker)
      assert_false destination.flush(timeout: 0.1)
      assert_nil(bounded_ractor_operation { worker.value })
    ensure
      release_writer&.close unless release_writer&.closed?
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(entered_port) if entered_port
      release_reader&.close unless release_reader&.closed?
    end

    def test_ractor_destination_close_records_an_abnormally_stopped_worker
      previous_report_on_exception = Thread.report_on_exception
      Thread.report_on_exception = false
      port = ::Ractor::Port.new
      failures = Queue.new
      destination = Julewire::Ractor::Destination.new(
        output: RactorPortOutput.new(port),
        request_timeout: 0.1,
        on_failure: ->(error, metadata) { failures << [error, metadata] }
      )
      worker = destination.instance_variable_get(:@worker)
      destination.instance_variable_get(:@port).send({ command: :unexpected })
      assert_raises(::Ractor::RemoteError) { worker.value }

      assert_false(bounded_ractor_operation { destination.close(timeout: 0.1) })
      observed = Array.new(2) { safe_queue_pop(failures, timeout: 0.1) }
      worker_stop = observed.find { |_error, metadata| metadata.fetch(:phase) == :worker_stop }

      assert_instance_of ::Ractor::RemoteError, worker_stop.fetch(0)
      assert_nil destination.instance_variable_get(:@port)
      assert_nil destination.instance_variable_get(:@worker)
    ensure
      Thread.report_on_exception = previous_report_on_exception if defined?(previous_report_on_exception)
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end
  end

  class TestRactorDestinationRestart < Minitest::Test
    cover "Julewire::Ractor::Destination#before_fork!"
    cover "Julewire::Ractor::Destination#after_fork!"
    cover "Julewire::Ractor::Destination#close_ports"
    cover "Julewire::Ractor::Destination#initialize_tracking"
    cover "Julewire::Ractor::Destination#spawn_worker"
    cover "Julewire::Ractor::Destination#start_worker"
    cover "Julewire::Ractor::Destination#wait_for_worker"
    include RactorRecordHelper
    include RactorWaitHelper

    def test_ractor_destination_can_restart_after_fork
      port = ::Ractor::Port.new
      failures = Queue.new
      destination = Julewire::Ractor::Destination.new(
        output: RactorPortOutput.new(port),
        request_timeout: 0.1,
        on_failure: ->(error, metadata) { failures << [error, metadata] }
      )
      old_command_port = destination.instance_variable_get(:@port)
      old_worker = destination.instance_variable_get(:@worker)
      old_ack_port = destination.instance_variable_get(:@ack_port)
      old_ack_thread = destination.instance_variable_get(:@ack_thread)

      safe_thread_value(safe_thread { destination.emit(record(message: "before-fork")) }, timeout: 0.1)

      assert_true destination.flush(timeout: 0.1)
      assert_equal "before-fork", JSON.parse(receive_ractor(port)).fetch("message")
      receive_ractor(port)
      wait_until { destination.health.dig(:counts, :worker_accepted) == 1 }

      assert_equal 1, destination.health.dig(:counts, :received)

      assert_same destination, destination.before_fork!(timeout: 0.1)
      assert_equal :flushed, receive_ractor(port)

      restarted = safe_thread_value(safe_thread { destination.after_fork! }, timeout: 0.25)

      assert_same destination, restarted
      assert_predicate old_command_port, :closed?
      assert_same old_ack_thread, old_ack_thread.join(0.1)
      assert_predicate old_ack_port, :closed?
      reset_health = destination.health

      assert_equal 0, reset_health.dig(:counts, :received)
      assert_equal 0, reset_health.dig(:counts, :queued)
      assert_equal 0, reset_health.fetch(:in_flight)

      safe_thread_value(safe_thread { destination.emit(record(message: "after-fork")) }, timeout: 0.1)

      assert_true destination.flush(timeout: 0.1)

      assert_equal "after-fork", JSON.parse(receive_ractor(port)).fetch("message")

      assert_same destination, destination.before_fork!(timeout: 0.1)
      assert_equal :flushed, receive_ractor(port)
      assert_nil destination.instance_variable_get(:@port)
      assert_nil destination.instance_variable_get(:@worker)
      assert_same destination, destination.after_fork!
      assert_empty nonblocking_queue_values(failures)
    ensure
      cleanup_ractor_worker(old_command_port, old_worker) if defined?(old_worker)
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_after_fork_does_not_reopen_a_closed_destination
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(output: RactorPortOutput.new(port))

      assert_true(bounded_ractor_operation { destination.close(timeout: 0.1) })
      assert_equal :flushed, receive_ractor(port)
      assert_same(destination, bounded_ractor_operation { destination.after_fork! })

      destination.emit(record(message: "after-restart"))

      assert_false destination.flush(timeout: 0.1)
      assert_equal :closed, destination.health.fetch(:status)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_records_prepared_restart_failures
      port = ::Ractor::Port.new
      failures = Queue.new
      output = TestRactorDestination::MutableCopyabilityOutput.new(port)
      destination = Julewire::Ractor::Destination.new(
        output: output,
        request_timeout: 0.1,
        on_failure: ->(error, metadata) { failures << [error, metadata] }
      )
      old_command_port = destination.instance_variable_get(:@port)
      old_worker = destination.instance_variable_get(:@worker)

      assert_same destination, destination.before_fork!(timeout: 0.1)

      output.make_non_copyable!

      restarted = safe_thread_value(safe_thread { destination.after_fork! }, timeout: 0.25)

      assert_same destination, restarted

      failure, metadata = safe_queue_pop(failures, timeout: 0.1)

      assert_instance_of ArgumentError, failure
      assert_match "ractor destination collaborators must be ractor-copyable or shareable", failure.message
      assert_equal :after_fork, metadata.fetch(:phase)
      refute_includes destination.health.fetch(:counts), :failures
      assert_nil destination.instance_variable_get(:@port)
      assert_nil destination.instance_variable_get(:@worker)
      assert_nil destination.instance_variable_get(:@ack_port)
      assert_nil destination.instance_variable_get(:@ack_thread)
    ensure
      cleanup_ractor_worker(old_command_port, old_worker) if defined?(old_worker)
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end
  end

  class TestRactorDestinationValidation < Minitest::Test
    cover "Julewire::Ractor::Destination#close"
    cover "Julewire::Ractor::Destination#initialize"
    cover "Julewire::Ractor::Destination#spawn_worker"
    cover "Julewire::Ractor::Destination#start_worker"
    include DroppingRactorDestinationHelper
    include RactorRecordHelper
    include RactorWaitHelper

    def test_ractor_destination_preserves_on_drop_callback_from_initialization
      port = ::Ractor::Port.new
      drops = Queue.new
      destination = Julewire::Ractor::Destination.new(
        output: RactorPortOutput.new(port),
        on_drop: ->(reason, metadata) { drops << [reason, metadata] }
      )
      bounded_ractor_operation { destination.close(timeout: 0.1) }

      destination.emit(record(message: "late", event: "ractor.late"))

      assert_equal(
        [
          :closed_dropped,
          { destination: :ractor, phase: :ractor_destination, reason: :closed_dropped }
        ],
        safe_queue_pop(drops, timeout: 0.1)
      )
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_rejects_non_copyable_collaborators
      error = assert_raises(ArgumentError) do
        Julewire::Ractor::Destination.new(output: NonCopyableOutput.new)
      end

      assert_match "ractor destination collaborators must be ractor-copyable or shareable", error.message
      assert_includes error.message, error.cause.message
    end

    def test_ractor_destination_validates_names_before_starting_worker
      assert_raises(ArgumentError) { Julewire::Ractor::Destination.new(output: Object.new, name: nil) }
      assert_raises(ArgumentError) { Julewire::Ractor::Destination.new(output: Object.new, name: Object.new) }
      assert_raises(ArgumentError) { Julewire::Ractor::Destination.new(output: Object.new, name: :"") }
    end
  end

  class TestRactorDestinationEmission < Minitest::Test
    cover "Julewire::Ractor::Destination#emit"
    cover "Julewire::Ractor::Destination#enqueue"
    cover "Julewire::Ractor::Destination#flush"
    cover "Julewire::Ractor::Destination#drop"
    cover "Julewire::Ractor::Destination#record_failure"
    cover "Julewire::Ractor::Destination#record_loss"
    cover "Julewire::Ractor::Destination#release_slot"
    cover "Julewire::Ractor::Destination#status_for"
    cover "Julewire::Ractor::Destination#increment"
    include DroppingRactorDestinationHelper
    include RactorRecordHelper
    include RactorWaitHelper

    def test_ractor_destination_formats_encodes_and_writes_in_worker
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(output: RactorPortOutput.new(port))
      emitted = record(message: "parallel", event: "ractor.destination")

      assert_nil safe_thread_value(safe_thread { destination.emit(emitted) }, timeout: 0.1)

      assert_true destination.flush(timeout: 0.1)

      messages = [receive_ractor(port), receive_ractor(port)]
      record = JSON.parse(messages.find { it.is_a?(String) })

      assert_equal "parallel", record.fetch("message")
      assert_equal "ractor.destination", record.fetch("event")
      assert_includes messages, :flushed
      wait_until { destination.health.dig(:counts, :worker_accepted) == 1 }
      health = destination.health

      assert_equal 1, health.dig(:counts, :received)
      assert_equal 1, health.dig(:counts, :queued)
      assert_equal 1, health.dig(:counts, :worker_accepted)
      assert_false health.key?(:last_loss)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_drops_when_in_flight_queue_is_full
      write_port = ::Ractor::Port.new
      drops = Queue.new
      destination = Julewire::Ractor::Destination.new(
        output: SlowRactorPortOutput.new(write_port),
        max_queue: 1,
        request_timeout: 0.01,
        on_drop: ->(reason, metadata) { drops << [reason, metadata] }
      )
      Julewire.configure { it.destinations.add(destination) }

      safe_thread_value(
        safe_thread { Julewire.emit(message: "first", event: "ractor.first", severity: :info, source: "test") },
        timeout: 0.1
      )
      first = receive_ractor(write_port)

      assert_equal 1, destination.health.fetch(:in_flight)

      safe_thread_value(
        safe_thread do
          Julewire.emit(message: "second", event: "ractor.queue_full", severity: :warn, source: "test")
        end,
        timeout: 0.1
      )

      assert_true Julewire.flush(timeout: 1)
      health = destination.health

      assert_equal "first", JSON.parse(first).fetch("message")
      assert_equal 2, health.dig(:counts, :received)
      assert_equal 1, health.dig(:counts, :queued)
      assert_equal 1, health.dig(:counts, :queue_full_dropped)
      assert_equal(
        { reason: :queue_full_dropped, event: "ractor.queue_full", severity: :warn, source: "test" },
        health.fetch(:last_loss)
      )
      assert_equal(
        [
          [
            :queue_full_dropped,
            { destination: :ractor, phase: :ractor_destination, reason: :queue_full_dropped }
          ]
        ],
        nonblocking_queue_values(drops)
      )
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(write_port) if write_port
    end

    def test_ractor_destination_reports_parent_send_failures_to_callback
      port = ::Ractor::Port.new
      failures = Queue.new
      destination = Julewire::Ractor::Destination.new(
        output: RactorPortOutput.new(port),
        on_failure: ->(error, metadata) { failures << [error.class, metadata] }
      )

      safe_thread_value(
        safe_thread do
          destination.emit(
            record(
              message: "bad",
              payload: { callback: proc {} },
              event: "ractor.send_error",
              severity: :error,
              source: "test"
            )
          )
        end,
        timeout: 0.1
      )
      health = destination.health

      assert_equal 1, health.dig(:counts, :received)
      assert_equal 0, health.dig(:counts, :queued)
      assert_equal 1, health.dig(:counts, :send_error)
      failure_class, metadata = safe_queue_pop(failures, timeout: 0.1)

      assert_equal TypeError, failure_class
      assert_equal :ractor_send, metadata.fetch(:phase)
      assert_equal :ractor, metadata.fetch(:destination)
      assert_equal 0, health.fetch(:in_flight)
      assert_equal "TypeError", health.dig(:last_failure, :class)
      assert_equal :ractor_send, health.dig(:last_failure, :phase)
      assert_equal :degraded, health.fetch(:status)
      refute_includes health.fetch(:counts), :failures
      assert_equal(
        { reason: :send_error, event: "ractor.send_error", severity: :error, source: "test" },
        health.fetch(:last_loss)
      )

      assert_true destination.flush(timeout: 0.1)
      assert_equal :flushed, receive_ractor(port)
      recovered_health = destination.health

      assert_equal :ok, recovered_health.fetch(:status)
      assert_equal :send_error, recovered_health.dig(:last_loss, :reason)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_drops_records_after_close
      port = ::Ractor::Port.new
      drops = Queue.new
      destination = Julewire::Ractor::Destination.new(
        output: RactorPortOutput.new(port),
        on_drop: ->(reason, metadata) { drops << [reason, metadata] }
      )

      assert_true(bounded_ractor_operation { destination.close(timeout: 0.1) })

      assert_nil destination.emit(record(message: "late", event: "ractor.closed", severity: :warn, source: "test"))
      health = destination.health

      assert_equal :closed, health.fetch(:status)
      assert_equal 1, health.dig(:counts, :received)
      assert_equal 0, health.dig(:counts, :queued)
      assert_equal 1, health.dig(:counts, :closed_dropped)
      assert_equal(
        { reason: :closed_dropped, event: "ractor.closed", severity: :warn, source: "test" },
        health.fetch(:last_loss)
      )
      assert_equal(
        [
          [
            :closed_dropped,
            { destination: :ractor, phase: :ractor_destination, reason: :closed_dropped }
          ]
        ],
        nonblocking_queue_values(drops)
      )
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end
  end
end
