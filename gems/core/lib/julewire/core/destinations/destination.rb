# frozen_string_literal: true

module Julewire
  module Core
    module Destinations
      class Destination
        COUNTER_KEYS = %i[
          callback_error
          encode_error
          formatter_error
          formatted
          output_accepted
          output_error
          output_exception
          output_rejected
          processor_dropped
          processor_error
          received
          record_too_large
        ].freeze

        attr_reader :name

        def initialize( # rubocop:disable Metrics/ParameterLists -- Destination definitions pass normalized settings.
          name:,
          close_output:,
          encoder:,
          formatter:,
          max_record_bytes:,
          on_drop:,
          on_failure:,
          output:,
          error_backtrace_lines: Core::MAX_BACKTRACE_LINES,
          processors: []
        )
          @name = Destinations.normalize_name(name)
          @formatter = validate_callable(formatter, name: :formatter)
          @encoder = validate_callable(encoder, name: :encoder)
          Validation.validate_byte_limit!(max_record_bytes, name: :max_record_bytes)
          @max_record_bytes = max_record_bytes
          @on_drop = validate_optional_callback(on_drop, name: :on_drop)
          @on_failure = validate_optional_callback(on_failure, name: :on_failure)
          raise ArgumentError, "destination #{@name.inspect} output is required" if output.nil?

          @output = Sink.wrap(output, close_output: close_output)
          @processor_chain = processor_chain(processors, error_backtrace_lines)
          initialize_tracking
          @write_step = build_write_step
        end

        def emit(record)
          degradation_marker = @health.degradation_marker
          record = process_record(record)
          return unless record

          emit_processed_record(record, degradation_marker: degradation_marker)
        end

        def emit_processed_record(record, degradation_marker:)
          return unless @write_step.call(record) == :accepted

          clear_degradation_if_unchanged(degradation_marker)
          nil
        end

        def flush(timeout: nil)
          call_output_lifecycle(:flush, timeout: timeout)
        end

        def close(timeout: nil)
          call_output_lifecycle(:close, timeout: timeout)
        end

        def after_fork!
          initialize_tracking
          @output.after_fork! if @output.respond_to?(:after_fork!)
          self
        rescue StandardError => e
          notify_failure(
            e,
            action: :after_fork,
            output_class: output_class_name,
            phase: :output_lifecycle
          )
          self
        end

        def resource_identity
          return @output.resource_identity if @output.respond_to?(:resource_identity)

          @output
        end

        def health
          {
            counts: counts_health,
            last_callback_failure: @health.last_callback_failure,
            last_failure: @health.last_failure,
            last_loss: @health.last_loss,
            status: degraded? ? :degraded : :ok
          }
        end

        private

        def counts_health
          @health.counts
        end

        def degraded?
          @health.degraded?
        end

        def initialize_tracking
          @health = Diagnostics::Health.new(
            counter_keys: COUNTER_KEYS,
            callback_metadata: { destination: name },
            callback_failure_counter: :callback_error
          )
        end

        def build_write_step
          WriteStep.new(
            formatter: @formatter,
            encoder: @encoder,
            output: @output,
            max_record_bytes: @max_record_bytes,
            increment: method(:increment_counter),
            failure: method(:record_write_step_failure),
            loss: method(:record_write_step_loss),
            output_class_name: method(:output_class_name)
          )
        end

        def notify_failure(error, **metadata)
          @health.record_failure(error, callback: @on_failure, **metadata)
        end

        def record_write_step_failure(error, metadata)
          notify_failure(error, **record_step_metadata(metadata))
        end

        def record_write_step_loss(reason, metadata)
          record_drop(reason, **record_step_metadata(metadata))
        end

        def record_step_metadata(metadata)
          record = metadata.delete(:record)
          metadata[:record_metadata] = Records::Metadata.call(record) if record
          metadata
        end

        def record_drop(reason, **metadata)
          record_loss(reason, metadata)
          callback_metadata = { destination: name, phase: :destination, reason: reason }.merge(metadata)
          callback_result = Diagnostics::CallbackNotifier.call(@on_drop, reason, callback_metadata)
          record_callback_error(callback_result) if Diagnostics::CallbackNotifier.failure?(callback_result)
        end

        def record_callback_error(callback_failure)
          @health.record_callback_failure(callback_failure)
        end

        def increment_counter(key)
          @health.increment(key)
        end

        def record_loss(reason, metadata)
          record_metadata = metadata.fetch(:record_metadata, {})
          @health.record_loss(
            reason: reason,
            counter: nil,
            at: Time.now.utc,
            event: record_metadata[:event],
            severity: record_metadata[:severity],
            source: record_metadata[:source]
          )
        end

        def clear_degradation
          @health.clear_degradation
        end

        def clear_degradation_if_unchanged(marker)
          @health.clear_degradation_if_unchanged(marker)
        end

        def validate_callable(callable, name:)
          Validation.validate_callable!(callable, name: name)
          callable
        end

        def validate_optional_callback(callback, name:)
          Validation.validate_callable!(callback, name: name, allow_nil: true)
          callback
        end

        def processor_chain(processors, error_backtrace_lines)
          processors = processor_entries(processors)
          return if processors.empty?

          Processing::ProcessorChain.new(
            processors: processors,
            error_backtrace_lines: error_backtrace_lines,
            on_error: method(:record_processor_error)
          )
        end

        def processor_entries(value)
          case value
          when Processing::ProcessorRegistry
            value.to_a
          else
            Processing::ProcessorRegistry.new(Array(value)).to_a
          end
        end

        def process_record(record)
          return record unless @processor_chain

          processed = @processor_chain.call(Records::Draft.from_record(record, freeze_sections: false))
          if processed.equal?(Processing::ProcessorChain::DROP)
            increment_counter(:processor_dropped)
            nil
          elsif processed.is_a?(Processing::ProcessorChain::ErrorResult)
            processed.draft.to_record
          else
            processed.to_record
          end
        rescue StandardError => e
          notify_failure(e, phase: :destination_processor, record_metadata: Records::Metadata.call(record))
          nil
        end

        def record_processor_error(error, record_metadata)
          increment_counter(:processor_error)
          notify_failure(error, phase: :destination_processor, record_metadata: record_metadata)
        end

        def call_output_lifecycle(method_name, timeout:)
          Validation.validate_timeout!(timeout, name: :timeout)
          call_output_lifecycle_safely(method_name, timeout)
        end

        def call_output_lifecycle_safely(method_name, timeout)
          # Sink.wrap centralizes timeout-aware lifecycle dispatch for every output.
          result = @output.public_send(method_name, timeout: timeout)
          clear_degradation if method_name == :flush && result != false
          result
        rescue StandardError => e
          notify_failure(
            e,
            action: method_name,
            output_class: output_class_name,
            phase: :output_lifecycle
          )
          false
        end

        def output_class_name
          return @output.output_class_name if @output.respond_to?(:output_class_name)

          @output.class.name
        end
      end
    end
  end
end
