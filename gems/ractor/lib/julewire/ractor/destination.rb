# frozen_string_literal: true

require "concurrent/atomic/atomic_fixnum"
require "concurrent/atomic/atomic_reference"

module Julewire
  module Ractor
    class Destination # rubocop:disable Metrics/ClassLength -- Owns parent queue, worker lifecycle, and health.
      class QueueSlots
        def initialize(max_queue:)
          @max_queue = max_queue
          @in_flight = Concurrent::AtomicFixnum.new
        end

        def value = @in_flight.value

        def reserve
          return true unless @max_queue.positive?

          result = {}
          @in_flight.update do |current|
            result[:reserved] = current < @max_queue
            result.fetch(:reserved) ? current + 1 : current
          end
          result.fetch(:reserved)
        end

        def release
          return false unless @max_queue.positive?

          result = {}
          @in_flight.update do |current|
            result[:underflow] = current.zero?
            current.positive? ? current - 1 : current
          end
          result.fetch(:underflow)
        end
      end

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
      WORKER_QUIESCE_MESSAGE = { command: :quiesce_worker }.freeze
      WORKER_STOP_MESSAGE = { command: :close_worker }.freeze
      private_constant :COUNTER_KEYS, :QueueSlots, :WORKER_QUIESCE_MESSAGE, :WORKER_STOP_MESSAGE

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
        raise ArgumentError, "request_timeout must be a non-negative finite Numeric" if request_timeout.nil?

        Core::Validation.validate_callable!(on_drop, name: :on_drop, allow_nil: true)
        Core::Validation.validate_callable!(on_failure, name: :on_failure, allow_nil: true)
        @output = output
        @max_record_bytes = max_record_bytes
        @max_queue = max_queue
        @close_output = close_output
        @request_timeout = request_timeout
        @on_drop = on_drop
        @on_failure = on_failure
        @fork_lifecycle_mutex = Mutex.new
        @prepared_for_fork = false
        initialize_tracking
        start_worker
      end

      def emit(record)
        increment(:received)
        outcome, error = enqueue(record)
        case outcome
        when :closed
          drop(:closed_dropped, record)
        when :queue_full
          drop(:queue_full_dropped, record)
        when :send_error
          record_failure(error, phase: :ractor_send)
          drop(:send_error, record)
        end
        nil
      end

      def flush(timeout: nil)
        @health.recover_if_successful { request(:flush, timeout: lifecycle_timeout(timeout)) }
      end

      def close(timeout: nil)
        timeout = lifecycle_timeout(timeout)
        @fork_lifecycle_mutex.synchronize { @closed.set(true) }
        result = request(:close, timeout: timeout, allow_closed: true)
        close_ports(timeout: timeout)
        result
      end

      def before_fork!(timeout: nil)
        timeout = lifecycle_timeout(timeout)
        @fork_lifecycle_mutex.synchronize do
          validate_before_fork_process!
          return self if @prepared_for_fork

          @closed.set(true)
          deadline = Core::Scheduling::Deadline.for(timeout)
          flush_before_fork!(Core::Scheduling::Deadline.remaining(deadline))
          stop_before_fork!(Core::Scheduling::Deadline.remaining(deadline))
          @prepared_for_fork = true
        end
        self
      rescue StandardError => e
        record_failure(e, phase: :before_fork)
        raise
      end

      def after_fork!
        @fork_lifecycle_mutex.synchronize do
          validate_after_fork_process!
          return self unless @prepared_for_fork

          initialize_tracking
          start_worker
          @prepared_for_fork = false
        end
        self
      rescue Core::UnsafeForkError => e
        record_failure(e, phase: :after_fork)
        raise
      rescue StandardError => e
        record_failure(e, phase: :after_fork)
        self
      end

      def resource_identity = self

      def health
        worker = request(:health, timeout: @request_timeout)
        if worker.equal?(false)
          worker = @worker_health.get
        else
          raise TypeError, "ractor destination health must be a Hash" unless worker.instance_of?(Hash)

          Core::Integration::Protocol.validate_symbol_keys(worker)
          @worker_health.set(worker)
        end

        @health.snapshot(
          in_flight: @queue_slots.value,
          max_queue: @max_queue,
          status: status_for(worker),
          worker: worker
        )
      end

      private

      def enqueue(record)
        @fork_lifecycle_mutex.synchronize do
          return [:closed, nil] if closed?
          return [:queue_full, nil] unless @queue_slots.reserve

          begin
            @port.send(
              { command: :emit, degradation_marker: @health.degradation_marker, record: record }
            )
            increment(:queued)
            [:queued, nil]
          rescue StandardError => e
            release_slot
            [:send_error, e]
          end
        end
      end

      def validate_before_fork_process!
        return if @process_id == Process.pid

        raise Core::UnsafeForkError,
              "ractor destination was inherited without Julewire.before_fork! in the parent process"
      end

      def validate_after_fork_process!
        return if @process_id == Process.pid || @prepared_for_fork

        raise Core::UnsafeForkError,
              "ractor destination was inherited without Julewire.before_fork! in the parent process"
      end

      def flush_before_fork!(timeout)
        return if request(:flush, timeout: timeout, allow_closed: true)

        @closed.set(false)
        raise Core::Error, "ractor destination could not flush before fork"
      end

      def stop_before_fork!(timeout)
        return if close_ports(timeout: timeout, stop_message: WORKER_QUIESCE_MESSAGE)

        raise Core::Error, "ractor destination worker did not stop before fork within #{timeout} seconds"
      end

      def validate_callable(callable, name:)
        Core::Validation.validate_callable!(callable, name: name)
        callable
      end

      def initialize_tracking
        @process_id = Process.pid
        @scheduler = ReplyTimeoutScheduler.new(timeout_value: false)
        @closed = Concurrent::AtomicReference.new
        @health = Core::Integration::DestinationHealth.new(counter_keys: COUNTER_KEYS, failure_counter: nil)
        @queue_slots = QueueSlots.new(max_queue: @max_queue)
        @worker_health = Concurrent::AtomicReference.new
      end

      def start_worker
        @ack_port = ::Ractor::Port.new
        PortLifecycle.with_port do |setup_port|
          @worker = spawn_worker(setup_port)
          @port = WorkerHandshake.receive(
            setup_port: setup_port,
            worker: @worker,
            scheduler: @scheduler
          )
        end
        @ack_thread = start_ack_thread
      rescue TypeError, ::Ractor::Error => e
        @port = @worker = @ack_port = @ack_thread = nil
        raise ArgumentError, "ractor destination collaborators must be ractor-copyable or shareable: #{e}"
      end

      def spawn_worker(setup_port)
        ack_port = @ack_port
        formatter = @formatter
        encoder = @encoder
        output = @output
        max_record_bytes = @max_record_bytes
        close_output = @close_output

        # simplecov:disable
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
        # simplecov:enable
      end

      def start_ack_thread
        ack_port = @ack_port
        thread = Thread.new do
          loop do
            message = ack_port.receive
            Core::Integration::Protocol.validate_symbol_hash(message)
            event = message.fetch(:event)
            unless event == :ack
              raise ArgumentError, "unknown ractor destination acknowledgement event: #{event.inspect}"
            end

            handle_ack(message)
          end
        rescue StandardError => e
          record_failure(e, phase: :ack)
        end
        thread.name = "julewire-ractor-destination-ack"
        thread
      end

      def handle_ack(message)
        release_slot
        case message.fetch(:status)
        when :accepted
          increment(:worker_accepted)
          @health.clear_degradation_if_unchanged(message.fetch(:degradation_marker))
        when :dropped
          increment(:worker_dropped)
        else
          raise ArgumentError, "unknown ractor destination acknowledgement status: #{message.fetch(:status).inspect}"
        end
      end

      def request(command, timeout:, allow_closed: false)
        return false if closed? && !allow_closed

        PortLifecycle.with_port do |reply|
          @port.send({ command: command, reply: reply })
          wait_for_reply(reply, timeout, command)
        end
      rescue StandardError => e
        record_failure(e, phase: :request, command: command)
        false
      end

      def wait_for_reply(reply, timeout, command)
        @scheduler.with_timeout(reply, timeout: timeout) do
          selected, value = ::Ractor.select(reply, @worker)
          return value if selected.equal?(reply)

          raise Core::Error, "ractor destination worker stopped before #{command} replied"
        end
      rescue ::Ractor::RemoteError
        raise Core::Error, "ractor destination worker stopped before #{command} replied"
      end

      def closed? = @closed.get

      def close_ports(timeout:, stop_message: WORKER_STOP_MESSAGE)
        worker_stopped = true
        begin
          if @worker
            begin
              @port.send(stop_message)
            rescue ::Ractor::ClosedError
              # A stopped worker no longer accepts commands. Still collect it
              # below so an abnormal exit remains observable.
            end
            worker_stopped = wait_for_worker(timeout)
          end
        rescue ::Ractor::RemoteError => e
          record_failure(e, phase: :worker_stop)
          worker_stopped = true
        ensure
          @ack_thread&.kill
          @ack_thread&.join
          PortLifecycle.close(@ack_port)
          @port = @worker = nil if worker_stopped
          @ack_port = nil
          @ack_thread = nil
        end

        worker_stopped
      end

      def wait_for_worker(timeout)
        PortLifecycle.with_port do |timeout_port|
          @scheduler.with_timeout(timeout_port, timeout: timeout) do
            selected, = ::Ractor.select(@worker, timeout_port)
            selected.equal?(@worker)
          end
        end
      end

      def lifecycle_timeout(timeout)
        Core::Validation.validate_timeout!(timeout, name: :timeout)
        timeout || @request_timeout
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
        @health.record_loss(
          reason: reason,
          event: record.event,
          severity: record.severity,
          source: record.source
        )
      end

      def record_failure(error, **metadata)
        @health.record_failure(error, **metadata)
        Core::Diagnostics::CallbackNotifier.call(@on_failure, error, { destination: name }.merge(metadata))
      end

      def release_slot
        # Late or duplicate ACKs can arrive after teardown/reset; keep them visible
        # without treating the ignored underflow as an operator-facing defect.
        increment(:slot_underflow_ignored) if @queue_slots.release
      end

      def increment(key)
        @health.increment(key)
      end

      def status_for(worker)
        return :closed if closed?

        :degraded if worker&.fetch(:status) == :degraded
      end
    end
  end
end
