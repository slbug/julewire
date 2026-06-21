# frozen_string_literal: true

module Julewire
  module Core
    module Execution
      class Scope
        EMPTY_HASH = {}.freeze
        private_constant :EMPTY_HASH

        attr_reader :finished_at

        def initialize(type:, id: nil, execution: EMPTY_HASH, execution_owned: false, summary_event: nil, # rubocop:disable Metrics/ParameterLists
                       summary_severity: nil, summary_source: nil, attributes: EMPTY_HASH, carry: EMPTY_HASH,
                       context: EMPTY_HASH, labels: EMPTY_HASH, neutral: EMPTY_HASH, parent: nil, started_at: nil)
          @identity = ScopeIdentity.new(
            type: type,
            id: id,
            started_at: started_at,
            parent: parent,
            parent_reference: parent&.execution_reference_for_child
          )
          @summary_state = summary_state(summary_event, summary_severity, summary_source)
          @execution = @identity.execution_fields(execution, owned: execution_owned)
          initialize_state(context: context, attributes: attributes, labels: labels, carry: carry, neutral: neutral)
        end

        def id = @identity.id

        def type = @identity.type

        def started_at = @identity.started_at

        def lineage = @identity.lineage

        def parent = @identity.parent

        def depth = @identity.depth

        def execution_hash
          Fields::FieldSet.deep_dup(frozen_execution_hash)
        end

        def frozen_execution_hash
          @frozen_execution_hash ||= @identity.frozen_execution_hash(@execution)
        end

        def inheritable_execution_hash
          Fields::FieldSet.deep_dup(@execution)
        end

        def context_hash = @fields.context_hash

        def carry_hash = @fields.carry_hash

        def attributes_hash = @fields.attributes_hash

        def neutral_hash = @fields.neutral_hash

        def field_stacks = @fields.stacks

        def labels_hash = @fields.labels_hash

        def frozen_labels_hash = @fields.frozen_labels_hash

        def field_hash(section)
          @fields.field_hash(section)
        end

        def field_stack(section)
          @fields.field_stack(section)
        end

        def summary_hash
          @summary_state.payload_hash
        end

        def metrics_hash
          @summary_state.metrics_hash
        end

        def measure_summary(key)
          measurement = @summary_state.measurement(key)
          started = monotonic_time
          begin
            yield
          ensure
            @summary_state.record_measurement(measurement, ((monotonic_time - started) * 1000).round(3))
          end
        end

        def measure_summary_start(key)
          measurement = @summary_state.measurement(key)
          started = monotonic_time
          MeasurementHandle.new do
            @summary_state.record_measurement(measurement, ((monotonic_time - started) * 1000).round(3))
          end
        end

        def add_field(section, fields, owned: false)
          @fields.add(section, fields, owned: owned)
        end

        def delete_carry(path)
          path = Fields::Internal.normalize_path(path)
          @fields.delete(:carry, path)
        end

        def with_field(section, fields, owned: false, &)
          @fields.with(section, fields, owned: owned, &)
        end

        def with_context(fields, &)
          with_field(:context, fields, &)
        end

        def with_carry(fields, &)
          with_field(:carry, fields, &)
        end

        def without_carry(path, &)
          normalized_path = Fields::Internal.normalize_path(path)
          raise ArgumentError, "carry path is required" if normalized_path.empty?

          @fields.without(:carry, normalized_path, &)
        end

        def add_summary(fields, owned: false)
          @summary_state.add(fields, owned: owned)
        end

        def add_summary_attributes(fields, owned: false)
          @summary_state.add_attributes(fields, owned: owned)
        end

        def add_summary_neutral(fields, owned: false)
          @summary_state.add_neutral(fields, owned: owned)
        end

        def increment_summary_attribute(path, by: 1)
          @summary_state.increment_attribute(path, by: by)
        end

        def increment_summary(key, by: 1)
          @summary_state.increment(key, by: by)
        end

        def append_summary(key, value)
          @summary_state.append(key, value)
        end

        def summary_record_input
          @summary_state.record_input(**summary_record_fields(timestamp: finished_at || frozen_time(Time.now.utc)))
        end

        def owned_summary_record_input
          @summary_state.owned_record_input(
            **summary_record_fields(timestamp: finished_at || frozen_time(Time.now.utc))
          )
        end

        def finished?
          !finished_at.nil?
        end

        def finish_owned(error: nil, severity: nil, finished_at: Time.now.utc)
          # The first completion snapshot wins; later finish calls are no-ops.
          return owned_summary_record_input if finished?

          record_error(error, severity: severity) if error
          @finished_at = frozen_time(finished_at)
          @summary_state.record_duration(((monotonic_time - @identity.started_monotonic) * 1000).round(3))
          @summary_state.finalize_record_input(**summary_record_fields(timestamp: @finished_at))
        end

        def record_error(error, severity: nil)
          @summary_state.record_error(error, severity: severity)
        end

        def non_standard_exception?
          @summary_state.non_standard_exception?
        end

        private

        def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        def frozen_time(value) = @identity.frozen_time(value)

        def initialize_state(context:, attributes:, labels:, carry: {}, neutral: {})
          @fields = ScopeFields.new(
            context: context,
            carry: carry,
            attributes: attributes,
            labels: labels,
            neutral: neutral
          )
          @finished_at = nil
        end

        def summary_state(event, severity, source)
          SummaryState.new(
            event: normalize_summary_event(event),
            severity: normalize_summary_severity(severity),
            source: normalize_summary_source(source)
          )
        end

        def normalize_summary_event(event)
          normalized = event.nil? ? "#{type}.completed" : event.to_s
          raise ArgumentError, "summary event is required" if normalized.empty?

          normalized
        end

        def normalize_summary_severity(severity)
          Records::Severity.normalize(severity) unless severity.nil?
        end

        def normalize_summary_source(source)
          normalized = source.nil? ? "julewire" : source.to_s
          raise ArgumentError, "summary source is required" if normalized.empty?

          normalized
        end

        def summary_record_fields(timestamp:)
          {
            timestamp: timestamp,
            execution: execution_hash,
            context: context_hash,
            carry: carry_hash,
            neutral: neutral_hash,
            attributes: attributes_hash,
            labels: labels_hash
          }
        end

        protected

        def execution_reference_for_child
          @identity.reference
        end
      end
    end
  end
end
