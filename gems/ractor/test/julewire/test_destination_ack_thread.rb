# frozen_string_literal: true

require "test_helper"
require "json"
require "timeout"

module Julewire
  class TestRactorDestinationAckThread < Minitest::Test
    cover "Julewire::Ractor::Destination#health"
    cover "Julewire::Ractor::Destination#handle_ack"
    cover "Julewire::Ractor::Destination#initialize"
    cover "Julewire::Ractor::Destination#start_ack_thread"

    class PortOutput
      def initialize(port)
        @port = port
      end

      def write(value) # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy write results.
        @port.send(value)
        true
      end
    end

    def test_applies_worker_acknowledgements_and_releases_its_port
      output_port = ::Ractor::Port.new
      destination = build_destination(output_port: output_port)
      ack_port = destination.instance_variable_get(:@ack_port)
      ack_thread = destination.instance_variable_get(:@ack_thread)

      %w[first second].each { destination.emit(record(it)) }

      messages = Array.new(2) { JSON.parse(receive_ractor(output_port)).fetch("message") }

      assert_equal %w[first second], messages
      wait_until { destination.health.dig(:counts, :worker_accepted) == 2 }

      assert_equal "julewire-ractor-destination-ack", ack_thread.name
      assert_equal 0, destination.health.fetch(:in_flight)

      assert_true(bounded_ractor_operation { destination.close(timeout: 0.1) })
      assert_same ack_thread, ack_thread.join(0.1)
      assert_predicate ack_port, :closed?
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(output_port) if output_port
    end

    def test_reports_string_keyed_protocol_violations
      output_port = ::Ractor::Port.new
      failures = Queue.new
      destination = build_destination(output_port: output_port, failures: failures)

      destination.instance_variable_get(:@ack_port).send({ "event" => :ack, "status" => :accepted })
      error, metadata = Timeout.timeout(0.1) { failures.pop }

      assert_instance_of TypeError, error
      assert_equal "record must not use string keys", error.message
      assert_equal :ack, metadata.fetch(:phase)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(output_port) if output_port
    end

    def test_reports_unknown_symbol_events
      output_port = ::Ractor::Port.new
      failures = Queue.new
      destination = build_destination(output_port: output_port, failures: failures)

      destination.instance_variable_get(:@ack_port).send({ event: :unexpected })
      error, metadata = Timeout.timeout(0.1) { failures.pop }

      assert_instance_of ArgumentError, error
      assert_equal "unknown ractor destination acknowledgement event: :unexpected", error.message
      assert_equal :ack, metadata.fetch(:phase)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(output_port) if output_port
    end

    def test_reports_unknown_acknowledgement_statuses
      output_port = ::Ractor::Port.new
      failures = Queue.new
      destination = build_destination(output_port: output_port, failures: failures)

      destination.instance_variable_get(:@ack_port).send({ event: :ack, status: :unexpected })
      error, metadata = Timeout.timeout(0.1) { failures.pop }

      assert_instance_of ArgumentError, error
      assert_equal "unknown ractor destination acknowledgement status: :unexpected", error.message
      assert_equal :ack, metadata.fetch(:phase)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(output_port) if output_port
    end

    def test_close_bounds_a_blocked_failure_callback
      output_port = ::Ractor::Port.new
      entered = Queue.new
      release = Queue.new
      callback = lambda do |_error, _metadata|
        entered << true
        release.pop
      end
      destination = Julewire::Ractor::Destination.new(
        output: PortOutput.new(output_port),
        on_failure: callback
      )
      ack_thread = destination.instance_variable_get(:@ack_thread)
      destination.instance_variable_get(:@ack_port).send({ event: :unexpected })
      Timeout.timeout(0.1) { entered.pop }

      assert_true Timeout.timeout(1) { destination.close(timeout: 0.5) }
      refute_predicate ack_thread, :alive?
    ensure
      release&.push(true)
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(output_port) if output_port
    end

    private

    def build_destination(output_port:, failures: nil)
      Julewire::Ractor::Destination.new(
        output: PortOutput.new(output_port),
        on_failure: failures && ->(error, metadata) { failures << [error, metadata] }
      )
    end

    def record(message)
      Julewire::Core::Records::Draft.build(
        { message: message, payload: {} },
        context: {},
        scope: nil
      ).to_record
    end

    def wait_until
      Timeout.timeout(0.1) { Thread.pass until yield }
    end
  end
end
