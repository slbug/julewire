# frozen_string_literal: true

require "concurrent/atomic/atomic_fixnum"
require "concurrent/atomic/atomic_reference"

module Julewire
  module Ractor
    class Destination # rubocop:disable Metrics/ClassLength -- Owns parent queue, worker lifecycle, and health.
      COUNTER_KEYS = %i[
        closed_dropped
        queue_full_dropped
        queued
        received
        send_error
        slot_underflow_ignored
        worker_accepted
        worker_dropped
      ].freeze
      DEFAULT_MAX_QUEUE = 1024
      DEFAULT_REQUEST_TIMEOUT = 1
      TIMEOUT_THREAD_NAME = "julewire-ractor-destination-timeout"
      private_constant :COUNTER_KEYS

      attr_reader :name

      def initialize( # rubocop:disable Metrics/ParameterLists -- Destination setup mirrors core destination knobs.
        output:,
        name: :ractor,
        formatter: Julewire::RecordFormatter.new,
        encoder: Julewire::JsonEncoder.new,
        max_record_bytes: Core::DEFAULT_MAX_RECORD_BYTES,
        max_queue: DEFAULT_MAX_QUEUE,
        close_output: false,
        request_timeout: DEFAULT_REQUEST_TIMEOUT,
        on_drop: nil,
        on_failure: nil
      )
        @name = Core::Destinations.normalize_name(name)
        @formatter = validate_callable(formatter, name: :formatter)
        @encoder = validate_callable(encoder, name: :encoder)
        Core::Destinations::Sink.validate_writeable!(output)
        Core::Validation.validate_byte_limit!(max_record_bytes, name: :max_record_bytes)
        Core::Validation.validate_non_negative_integer!(max_queue, name: :max_queue)
        Core::Validation.validate_timeout!(request_timeout, name: :request_timeout)
        Core::Validation.validate_callable!(on_drop, name: :on_drop, allow_nil: true)
        Core::Validation.validate_callable!(on_failure, name: :on_failure, allow_nil: true)
        @output = output
        @max_record_bytes = max_record_bytes
        @max_queue = max_queue
        @close_output = close_output
        @request_timeout = request_timeout
        @on_drop = on_drop
        @on_failure = on_failure
        @scheduler = Core::Scheduling::DeadlineScheduler.new(thread_name: TIMEOUT_THREAD_NAME, idle: :exit)
        initialize_tracking
        start_worker
      end

      def emit(record)
        increment(:received)
        return drop(:closed_dropped, record) if closed?
        return drop(:queue_full_dropped, record) unless reserve_slot

        begin
          @port.send({ command: :emit, record: record })
          increment(:queued)
        rescue StandardError => e
          release_slot
          record_failure(e, phase: :ractor_send)
          drop(:send_error, record)
        end
        nil
      end

      def flush(timeout: nil)
        timeout = @request_timeout if timeout.nil?
        request(:flush, timeout: timeout)
      end

      def close(timeout: nil)
        timeout = @request_timeout if timeout.nil?
        @closed.set(true)
        result = request(:close, timeout: timeout)
        close_ports
        result
      end

      def after_fork!
        close_ports
        @scheduler.after_fork!
        initialize_tracking
        start_worker
        self
      rescue StandardError => e
        record_failure(e, phase: :after_fork)
        self
      end

      def resource_identity = self

      def health
        worker = request(:health, timeout: @request_timeout)
        worker = @worker_health.get unless worker.is_a?(Hash)
        @worker_health.set(worker) if worker.is_a?(Hash)

        @health.snapshot(
          in_flight: @in_flight.value,
          max_queue: @max_queue,
          status: status_for(worker),
          worker: worker
        )
      end

      private

      def validate_callable(callable, name:)
        Core::Validation.validate_callable!(callable, name: name)
        callable
      end

      def initialize_tracking
        @closed = Concurrent::AtomicReference.new(false)
        @health = Core::Integration::DestinationHealth.new(counter_keys: COUNTER_KEYS, failure_counter: nil)
        @in_flight = Concurrent::AtomicFixnum.new(0)
        @worker_health = Concurrent::AtomicReference.new
      end

      def start_worker
        @ack_port = ::Ractor::Port.new
        setup_port = ::Ractor::Port.new
        @worker = spawn_worker(setup_port)
        @port = receive_worker_port(setup_port)
        @ack_thread = start_ack_thread
      rescue StandardError => e
        raise ArgumentError, "ractor destination collaborators must be ractor-copyable or shareable: #{e.message}"
      ensure
        PortLifecycle.close(setup_port) if defined?(setup_port) && setup_port
      end

      def spawn_worker(setup_port)
        ack_port = @ack_port
        formatter = @formatter
        encoder = @encoder
        output = @output
        max_record_bytes = @max_record_bytes
        close_output = @close_output

        # :nocov:
        ::Ractor.new(setup_port, ack_port, formatter, encoder, output, max_record_bytes, close_output,
                     name: "julewire-ractor-destination") do |worker_port, worker_ack_port, worker_formatter,
                                                             worker_encoder, worker_output, worker_max_record_bytes,
                                                             worker_close_output|
          command_port = ::Ractor::Port.new
          worker_port.send(command_port)
          DestinationWorker.run(
            command_port: command_port,
            ack_port: worker_ack_port,
            formatter: worker_formatter,
            encoder: worker_encoder,
            output: worker_output,
            max_record_bytes: worker_max_record_bytes,
            close_output: worker_close_output
          )
        end
        # :nocov:
      end

      def receive_worker_port(setup_port)
        selected, value = ::Ractor.select(setup_port, @worker)
        return value if selected.equal?(setup_port) && value.is_a?(::Ractor::Port)

        raise ArgumentError, "ractor destination worker did not start"
      end

      def start_ack_thread
        thread = Thread.new do
          loop do
            message = @ack_port.receive
            break if message.is_a?(Hash) && message[:event] == :closed

            handle_ack(message)
          end
        rescue StandardError => e
          record_failure(e, phase: :ack)
        end
        thread.name = "julewire-ractor-destination-ack"
        thread.report_on_exception = true
        thread
      end

      def handle_ack(message)
        return unless message.is_a?(Hash) && message[:event] == :ack

        decrement_in_flight
        case message[:status]
        when :accepted
          increment(:worker_accepted)
        when :dropped
          increment(:worker_dropped)
        end
      end

      def request(command, timeout:)
        return false if closed? && command != :health && command != :close

        reply = ::Ractor::Port.new
        @port.send({ command: command, reply: reply })
        wait_for_reply(reply, timeout)
      rescue StandardError => e
        record_failure(e, phase: :request, command: command)
        false
      ensure
        PortLifecycle.close(reply) if reply
      end

      def wait_for_reply(reply, timeout)
        return reply.receive unless timeout

        timeout_port = ::Ractor::Port.new
        token = @scheduler.schedule(timeout) do
          timeout_port.send(:timeout)
        rescue StandardError
          nil
        end
        selected, response = ::Ractor.select(reply, timeout_port)

        selected.equal?(timeout_port) ? false : response
      ensure
        @scheduler.cancel(token) if defined?(token)
        PortLifecycle.close(timeout_port) if defined?(timeout_port) && timeout_port
      end

      def reserve_slot
        return true unless @max_queue.positive?

        # MRI normally settles this in one pass under the GVL; the CAS loop keeps
        # the reservation honest when multiple emitters race.
        loop do
          current = @in_flight.value
          return false if current >= @max_queue
          return true if @in_flight.compare_and_set(current, current + 1)
        end
      end

      def closed? = @closed.get

      def close_ports
        @port&.send({ command: :close_worker }) unless @port&.closed?
      rescue StandardError
        nil
      ensure
        PortLifecycle.close(@port) if @port
        PortLifecycle.close(@ack_port) if @ack_port
      end

      def drop(reason, record)
        record_loss(reason, record)
        Core::Diagnostics::CallbackNotifier.call(
          @on_drop,
          reason,
          { destination: name, phase: :ractor_destination, reason: reason }
        )
        nil
      end

      def record_loss(reason, record)
        metadata = Core::Records::Metadata.call(record)
        @health.record_loss(
          reason: reason,
          event: metadata[:event],
          severity: metadata[:severity],
          source: metadata[:source]
        )
      end

      def record_failure(error, **metadata)
        @health.record_failure(error, counter: nil, **metadata)
        Core::Diagnostics::CallbackNotifier.call(@on_failure, error, { destination: name }.merge(metadata))
      rescue StandardError
        nil
      end

      def release_slot
        loop do
          current = @in_flight.value
          if current <= 0
            # Late or duplicate ACKs can arrive after teardown/reset; keep them visible
            # without treating the ignored underflow as an operator-facing defect.
            increment(:slot_underflow_ignored)
            return
          end
          return if @in_flight.compare_and_set(current, current - 1)
        end
      end

      def decrement_in_flight
        release_slot
      end

      def increment(key)
        @health.increment(key)
      end

      def status_for(worker)
        return :closed if closed?
        return :degraded if @health.degraded?
        return :degraded if worker.is_a?(Hash) && worker[:status] == :degraded

        :ok
      end
    end
  end
end
