# frozen_string_literal: true

module Julewire
  module Core
    module Destinations
      # @api extension
      class TailSampling # rubocop:disable Metrics/ClassLength -- Owns execution buffering plus destination lifecycle.
        COUNTER_KEYS = %i[
          buffered
          emitted
          failures
          immediate
          overflow_dropped
          policy_dropped
          received
        ].freeze
        DEFAULT_MAX_EXECUTIONS = 1024
        DEFAULT_MAX_RECORDS_PER_EXECUTION = 1000
        DEFAULT_SAMPLE_RATE = 0.1
        ERROR_RANK = Records::Severity.rank(:error)
        OPTION_KEYS = %i[
          decider
          max_executions
          max_records_per_execution
          name
          on_drop
          on_failure
          sample_rate
          slow_ms
        ].freeze
        private_constant :COUNTER_KEYS, :ERROR_RANK, :OPTION_KEYS

        TailOptions = Data.define(:decider, :max_executions, :max_records_per_execution, :name, :on_drop, :on_failure,
                                  :sample_rate, :slow_ms)
        private_constant :TailOptions

        attr_reader :name

        def initialize(destination:, **options)
          Validation.validate_options!(options, OPTION_KEYS, name: :tail_sampling)
          options = tail_options(options)
          @destination = Registry.validate!(destination)
          @name = Destinations.normalize_name(options.name)
          @sample_rate = options.sample_rate
          Processing::Sampling.threshold_for(options.sample_rate)
          @slow_ms = validate_slow_ms(options.slow_ms)
          @max_executions = Validation.validate_integer_limit!(
            options.max_executions,
            name: :max_executions,
            positive: true
          )
          @max_records_per_execution = Validation.validate_integer_limit!(
            options.max_records_per_execution,
            name: :max_records_per_execution,
            positive: true
          )
          Validation.validate_callable!(options.decider, name: :decider, allow_nil: true)
          Validation.validate_callable!(options.on_drop, name: :on_drop, allow_nil: true)
          Validation.validate_callable!(options.on_failure, name: :on_failure, allow_nil: true)
          @decider = options.decider
          @on_drop = options.on_drop
          @on_failure = options.on_failure
          initialize_state
        end

        def emit(record)
          result = @mutex.synchronize { accept_record(record) }
          result.losses.compact.each { notify_drop(it) }
          result.records.each { emit_target(it) }
          nil
        rescue StandardError => e
          record_failure(e, record)
          nil
        end

        def flush(timeout: nil)
          drain_and_lifecycle(:flush, timeout: timeout)
        end

        def close(timeout: nil)
          drain_and_lifecycle(:close, timeout: timeout)
        end

        def after_fork!
          @mutex.synchronize { initialize_buffer }
          @destination.after_fork! if @destination.respond_to?(:after_fork!)
          self
        rescue StandardError => e
          record_failure(e, nil, phase: :after_fork)
          self
        end

        def resource_identity = self

        def health
          buffered_executions = @mutex.synchronize { @buffers.length }
          destination = destination_health
          status = health_status
          @health.snapshot(
            buffered_executions: buffered_executions,
            destination: destination,
            max_executions: @max_executions,
            max_records_per_execution: @max_records_per_execution,
            sample_rate: @sample_rate,
            slow_ms: @slow_ms,
            status: status
          )
        end

        private

        EmitResult = Data.define(:records, :losses)
        Buffer = Data.define(:records)
        private_constant :Buffer, :EmitResult

        def tail_options(options)
          TailOptions.new(
            decider: options[:decider],
            max_executions: options.fetch(:max_executions, DEFAULT_MAX_EXECUTIONS),
            max_records_per_execution: options.fetch(:max_records_per_execution, DEFAULT_MAX_RECORDS_PER_EXECUTION),
            name: options.fetch(:name, :tail_sampling),
            on_drop: options[:on_drop],
            on_failure: options[:on_failure],
            sample_rate: options.fetch(:sample_rate, DEFAULT_SAMPLE_RATE),
            slow_ms: options[:slow_ms]
          )
        end

        def initialize_state
          @mutex = Mutex.new
          initialize_buffer
          @health = Integration::DestinationHealth.new(counter_keys: COUNTER_KEYS)
        end

        def initialize_buffer
          @buffers = {}
          @order = []
        end

        def accept_record(record)
          @health.increment(:received)
          key = execution_key(record)
          return immediate(record) unless key

          if summary_record?(record)
            finish_execution(key, record)
          else
            buffer_record(key, record)
          end
        end

        def immediate(record)
          @health.increment(:immediate)
          EmitResult.new([record], [])
        end

        def buffer_record(key, record)
          losses = ensure_execution_capacity(key)
          buffer = (@buffers[key] ||= begin
            @order << key
            Buffer.new([])
          end)
          if buffer.records.length >= @max_records_per_execution
            dropped = buffer.records.shift
            losses << record_loss(:overflow_dropped, dropped)
          end
          buffer.records << record
          @health.increment(:buffered)
          EmitResult.new([], losses)
        end

        def ensure_execution_capacity(key)
          return [] if @buffers.key?(key)
          return [] if @buffers.length < @max_executions

          oldest = @order.shift
          buffer = @buffers.delete(oldest)
          Array(buffer&.records).map { record_loss(:overflow_dropped, it) }
        end

        def finish_execution(key, summary)
          buffer = @buffers.delete(key)
          @order.delete(key)
          records = Array(buffer&.records)
          records << summary
          if keep_execution?(summary, key)
            @health.increment(:emitted, by: records.length)
            EmitResult.new(records, [])
          else
            EmitResult.new([], records.map { record_loss(:policy_dropped, it) })
          end
        end

        def drain_buffered_records
          records = @order.flat_map { @buffers.fetch(it).records }
          initialize_buffer
          @health.increment(:emitted, by: records.length)
          records
        end

        def drain_and_lifecycle(method_name, timeout:)
          records = @mutex.synchronize { drain_buffered_records }
          records.each { emit_target(it) }
          lifecycle(method_name, timeout: timeout)
        end

        def keep_execution?(record, key)
          return !!@decider.call(record, key: key) if @decider

          default_keep_execution?(record, key)
        rescue StandardError => e
          record_failure(e, record, phase: :tail_sampling_decider)
          false
        end

        def default_keep_execution?(record, key)
          error_record?(record) || slow_record?(record) || Processing::Sampling.keep?(rate: @sample_rate, key: key)
        end

        def error_record?(record)
          return true if record[:error]

          Records::Severity.rank(record[:severity]) >= ERROR_RANK
        rescue StandardError
          false
        end

        def slow_record?(record)
          return false unless @slow_ms

          duration = field_value(record[:metrics], :duration_ms)
          duration.is_a?(Numeric) && duration >= @slow_ms
        end

        def summary_record?(record) = record[:kind] == :summary

        def execution_key(record)
          reference = record.respond_to?(:lineage) ? record.lineage.root_reference : nil
          reference = record[:execution] unless reference.is_a?(Hash)
          id = field_value(reference, :id)
          return unless id

          [field_value(reference, :type), id].freeze
        rescue StandardError
          nil
        end

        def field_value(hash, key)
          Fields::FieldSet.value_for(hash, key)
        end

        def emit_target(record)
          @destination.emit(record)
        rescue StandardError => e
          record_failure(e, record, phase: :tail_sampling_destination)
        end

        def lifecycle(method_name, timeout:)
          @destination.public_send(method_name, timeout: timeout) != false
        rescue StandardError => e
          record_failure(e, nil, phase: :tail_sampling_lifecycle, action: method_name)
          false
        end

        def destination_health
          @destination.health
        rescue StandardError => e
          Diagnostics::FailureSnapshot.build(e, destination: @destination.name, phase: :tail_sampling_health)
        end

        def record_loss(reason, record)
          @health.record_loss(reason: reason, record_metadata: Records::Metadata.call(record))
        rescue StandardError => e
          record_failure(e, record, phase: :tail_sampling_drop)
        end

        def notify_drop(loss)
          @on_drop&.call(loss.fetch(:reason), loss)
        rescue StandardError => e
          record_failure(e, nil, phase: :tail_sampling_drop_callback)
        end

        def record_failure(error, record, phase: :tail_sampling, **metadata)
          failure_metadata = if @mutex.owned?
                               record_failure_state(error, record, phase: phase, **metadata)
                             else
                               @mutex.synchronize { record_failure_state(error, record, phase: phase, **metadata) }
                             end
          @on_failure&.call(error, **failure_metadata)
        rescue StandardError
          nil
        end

        def record_failure_state(error, record, phase:, **metadata)
          @health.record_failure(
            error,
            **metadata,
            destination: @name,
            phase: phase,
            record_metadata: record ? Records::Metadata.call(record) : nil
          )
          metadata.merge(destination: @name, phase: phase)
        end

        def health_status
          return :degraded if @health.last_failure || @health.last_loss&.fetch(:reason) == :overflow_dropped

          :ok
        end

        def validate_slow_ms(value)
          return if value.nil?
          raise ArgumentError, "slow_ms must be a non-negative Numeric" unless value.is_a?(Numeric) && value.finite?
          raise ArgumentError, "slow_ms must be non-negative" if value.negative?

          value
        end
      end
    end
  end
end
