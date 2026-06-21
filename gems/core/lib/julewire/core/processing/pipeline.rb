# frozen_string_literal: true

module Julewire
  module Core
    module Processing
      class Pipeline # rubocop:disable Metrics/ClassLength -- Pipeline owns normalization, processors, and destinations.
        COUNTER_KEYS = %i[
          callback_error
          entered
          level_dropped
          no_output_dropped
          processor_dropped
          processor_error
        ].freeze
        EMPTY_HASH = {}.freeze
        private_constant :EMPTY_HASH

        # @api integration_spi
        # Integration-facing raw/normalized record pipeline.
        def initialize(configuration:, invalid_severity_reporter: Diagnostics::InvalidSeverityReporter.counter)
          @on_drop = configuration.on_drop
          @on_failure = configuration.on_failure
          @invalid_severity_reporter = invalid_severity_reporter
          @destinations = build_destinations(configuration)
          @labels = Fields::FieldSet.deep_symbolize_keys(configuration.labels.to_h)
          @threshold = build_threshold(configuration)
          @error_backtrace_lines = configuration.error_backtrace_lines
          Validation.validate_callable!(configuration.on_failure, name: :on_failure, allow_nil: true)
          @processor_chain = build_processor_chain(configuration)
          @processors_empty = @processor_chain.empty?
          @labels_empty = @labels.empty?
          initialize_tracking
        end

        def emit(input = Core::UNSET, **fields, &)
          emit_with_level_check(input, true, fields, &)
        end

        def emit_without_level(input = Core::UNSET, **fields, &)
          emit_with_level_check(input, false, fields, &)
        end

        # Trusted integration path for adapter-owned input hashes.
        def emit_integration(input, enforce_level: true)
          emit_input_with_guard(input, enforce_level: enforce_level, lazy: false) do
            build_draft(input, input_owned: true)
          end
        end

        # Runtime summaries already carry their captured scope fields.
        def emit_isolated_input(input, enforce_level: true)
          emit_input_with_guard(input, enforce_level: enforce_level, lazy: false) do
            build_isolated_draft(input)
          end
        end

        # Trusted normalized-record path used by runtime summaries and bridge envelopes.
        def emit_record(record, enforce_level: true)
          return if no_output_dropped?

          degradation_marker = @health.degradation_marker
          emit_validated_record(record, enforce_level: enforce_level)
          finish_emit_attempt(degradation_marker)
        rescue StandardError => e
          record_emit_failure(e, record)
        end

        def after_fork!
          initialize_tracking
          @destinations.after_fork!
          self
        end

        def flush(timeout: nil)
          @destinations.flush(timeout: timeout)
        end

        def close(timeout: nil, skip_resource_identities: nil)
          @destinations.close(timeout: timeout, skip_resource_identities: skip_resource_identities)
        end

        def lifecycle_resource_identities
          @destinations.lifecycle_resource_identities
        end

        def health
          {
            configured: !@destinations.empty?,
            counts: pipeline_counts_snapshot,
            destinations: @destinations.health,
            last_callback_failure: @health.last_callback_failure,
            last_failure: @health.last_failure,
            status: pipeline_status
          }
        end

        private

        def build_destinations(configuration)
          Destinations::Collection.build(
            configuration: configuration,
            defaults: destination_defaults(configuration),
            on_drop: method(:record_destination_drop),
            on_failure: method(:notify_failure)
          )
        end

        def destination_defaults(configuration)
          {
            encoder: Serialization::JsonEncoder.new(max_backtrace_lines: configuration.error_backtrace_lines),
            formatter: Records::Formatter.new,
            error_backtrace_lines: configuration.error_backtrace_lines,
            on_drop: configuration.on_drop,
            on_failure: configuration.on_failure
          }
        end

        def build_threshold(configuration)
          LevelThreshold.new(
            level: configuration.level,
            invalid_severity_reporter: @invalid_severity_reporter
          )
        end

        def build_processor_chain(configuration)
          ProcessorChain.new(
            processors: configuration.processors.to_a.freeze,
            error_backtrace_lines: @error_backtrace_lines,
            on_error: method(:record_processor_error)
          )
        end

        def emit_with_level_check(input, enforce_level, fields, &)
          input = Core.emit_input(input, fields)

          emit_input_with_guard(input, enforce_level: enforce_level, lazy: block_given?) do
            input = Records::LazyEmitInput.call(input, &) if block_given?
            build_draft(input)
          end
        end

        def emit_input_with_guard(input, enforce_level:, lazy:)
          return if no_output_dropped?

          degradation_marker = @health.degradation_marker
          if raw_input_blocked?(input, enforce_level: enforce_level, lazy: lazy)
            increment_pipeline_counter(:level_dropped)
          else
            emit_prepared_draft(yield, enforce_level: enforce_level, merge_static_labels: false)
          end
          finish_emit_attempt(degradation_marker)
        rescue StandardError => e
          notify_failure(e, phase: :emit)
          emit_internal_error_record(e)
          nil
        end

        def no_output_dropped?
          return false unless @destinations.empty?

          record_no_output_drop
          true
        end

        def finish_emit_attempt(degradation_marker)
          clear_degradation_if_unchanged(degradation_marker)
          nil
        end

        def emit_validated_record(record, enforce_level:)
          Records::Record.validate_normalized!(record)
          return emit_fast_record(record, enforce_level: enforce_level) if fast_record_path?

          emit_prepared_draft(Records::Draft.from_record(record, freeze_sections: false),
                              enforce_level: enforce_level)
          nil
        end

        def fast_record_path?
          @labels_empty && @processors_empty
        end

        def emit_fast_record(record, enforce_level:)
          if enforce_level && !emit_record?(record)
            increment_pipeline_counter(:level_dropped)
            return
          end

          increment_pipeline_counter(:entered)
          emit_to_destinations(record)
          nil
        end

        def raw_input_blocked?(input, enforce_level:, lazy:)
          enforce_level &&
            (!lazy || Records::RawInput.explicit_severity?(input)) &&
            !@threshold.raw_input_allowed?(input)
        end

        def build_draft(input, input_owned: false)
          store = ContextStore.current
          build_draft_from(
            input,
            input_owned: input_owned,
            context: store.context_hash,
            neutral: store.neutral_hash,
            attributes: store.attributes_hash,
            carry: store.carry_hash,
            scope: store.current_scope_or_snapshot
          )
        end

        def build_isolated_draft(input, input_owned: false)
          build_draft_from(
            input,
            input_owned: input_owned,
            context: EMPTY_HASH,
            neutral: EMPTY_HASH,
            attributes: EMPTY_HASH,
            carry: EMPTY_HASH,
            scope: nil
          )
        end

        def build_draft_from(input, input_owned:, context:, neutral:, attributes:, carry:, scope:)
          Records::Draft.build_pipeline_owned(
            input,
            context: context,
            neutral: neutral,
            attributes: attributes,
            carry: carry,
            static_labels: @labels,
            input_owned: input_owned,
            freeze_sections: @processors_empty,
            scope: scope,
            error_backtrace_lines: @error_backtrace_lines,
            invalid_severity_reporter: @invalid_severity_reporter
          )
        end

        def initialize_tracking
          @health = Diagnostics::Health.new(
            counter_keys: COUNTER_KEYS,
            callback_metadata: {},
            callback_failure_counter: :callback_error
          )
        end

        def pipeline_status
          return :unconfigured if @destinations.empty?

          @health.degraded? ? :degraded : :ok
        end

        def clear_degradation_if_unchanged(marker)
          @health.clear_degradation_if_unchanged(marker)
        end

        def merge_static_labels(draft)
          return draft if @labels_empty

          draft[:labels] = Fields::FieldSet.merge(@labels, draft.fetch(:labels))
          draft
        end

        def emit_record?(record_or_draft)
          @threshold.allow?(record_or_draft.fetch(:severity))
        end

        def emit_prepared_draft(draft, enforce_level:, merge_static_labels: true)
          if enforce_level && !emit_record?(draft)
            increment_pipeline_counter(:level_dropped)
            return
          end

          draft = merge_static_labels(draft) if merge_static_labels
          increment_pipeline_counter(:entered)
          emit_processed_draft(draft, enforce_level: enforce_level)
        rescue StandardError => e
          record_emit_failure(e, draft)
        end

        def emit_processed_draft(draft, enforce_level:)
          return emit_to_destinations(draft.to_record) if @processors_empty

          processed = @processor_chain.call(draft)
          if processed.equal?(ProcessorChain::DROP)
            increment_pipeline_counter(:processor_dropped)
            return
          end

          processed, enforce_processed_level = processed_draft_and_level(processed, enforce_level)

          if enforce_processed_level && !emit_record?(processed)
            increment_pipeline_counter(:level_dropped)
            return
          end

          emit_to_destinations(processed.to_record)
        end

        def processed_draft_and_level(processed, default_enforce_level)
          if processed.is_a?(ProcessorChain::ErrorResult)
            [processed.draft, false]
          else
            [processed, default_enforce_level]
          end
        end

        def record_processor_error(error, record_metadata)
          increment_pipeline_counter(:processor_error)
          notify_failure(error, phase: :processor, record_metadata: record_metadata)
        end

        def emit_internal_error_record(error)
          emit_prepared_draft(
            Diagnostics::InternalRecords.emit_error(error, error_backtrace_lines: @error_backtrace_lines),
            enforce_level: false
          )
        rescue StandardError => e
          notify_failure(e, phase: :internal_error_record)
          nil
        end

        def emit_to_destinations(record)
          @destinations.emit(record)
        end

        def record_no_output_drop
          increment_pipeline_counter(:no_output_dropped)
          nil
        end

        def notify_failure(error, **metadata)
          @health.record_failure(error, callback: @on_failure, **metadata)
        end

        def record_destination_drop(reason, **metadata)
          callback_result = Diagnostics::CallbackNotifier.call(@on_drop, reason, metadata.merge(reason: reason))
          return unless Diagnostics::CallbackNotifier.failure?(callback_result)

          @health.record_callback_failure(callback_result)
        end

        def record_emit_failure(error, record)
          notify_failure(error, phase: :emit_record, record_metadata: Records::Metadata.call(record))
          nil
        end

        def pipeline_counts_snapshot
          @health.counts
        end

        def increment_pipeline_counter(key)
          @health.increment(key)
        end
      end
    end
  end
end
