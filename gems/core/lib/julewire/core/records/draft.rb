# frozen_string_literal: true

require "time"

module Julewire
  module Core
    module Records
      # @api extension
      class Draft
        include Enumerable
        include Deconstruct

        class << self
          def build( # rubocop:disable Metrics/ParameterLists -- Record construction has fixed public sections.
            input = {},
            context:,
            scope:,
            attributes: {},
            neutral: {},
            carry: {},
            static_labels: {},
            freeze_sections: true,
            error_backtrace_lines: Core::MAX_BACKTRACE_LINES,
            invalid_severity_reporter: Diagnostics::InvalidSeverityReporter
          )
            build_with(
              input,
              context: context,
              neutral: neutral,
              attributes: attributes,
              carry: carry,
              static_labels: static_labels,
              scope: scope,
              invalid_severity_reporter: invalid_severity_reporter,
              options: BuildOptions.defensive(
                freeze_sections: freeze_sections,
                error_backtrace_lines: error_backtrace_lines
              )
            )
          end

          def build_pipeline_owned( # rubocop:disable Metrics/ParameterLists -- Record construction has fixed public sections.
            input = {},
            context:,
            scope:,
            attributes: {},
            neutral: {},
            carry: {},
            static_labels: {},
            input_owned: false,
            freeze_sections: true,
            error_backtrace_lines: Core::MAX_BACKTRACE_LINES,
            invalid_severity_reporter: Diagnostics::InvalidSeverityReporter
          )
            build_with(
              input,
              context: context,
              neutral: neutral,
              attributes: attributes,
              carry: carry,
              static_labels: static_labels,
              scope: scope,
              invalid_severity_reporter: invalid_severity_reporter,
              options: BuildOptions.pipeline_owned(
                input_owned: input_owned,
                freeze_sections: freeze_sections,
                error_backtrace_lines: error_backtrace_lines
              )
            )
          end

          private

          def build_with(input, context:, neutral:, attributes:, carry:, static_labels:, scope:, # rubocop:disable Metrics/ParameterLists
                         invalid_severity_reporter:, options:)
            builder = Builder.new(
              input,
              context: context,
              neutral: neutral,
              attributes: attributes,
              carry: carry,
              static_labels: static_labels,
              scope: scope,
              invalid_severity_reporter: invalid_severity_reporter,
              options: options
            )
            new(builder.to_h, lineage: builder.lineage, freeze_sections: options.freeze_sections)
          end

          public

          def from_normalized_hash(data, lineage: nil, freeze_sections: true)
            Record.validate_normalized_hash!(data)
            normalized = data.dup
            lineage ||= Execution::Lineage.from_execution_hash(normalized[:execution])
            normalized[:execution] = Execution::Lineage.clean_normalized_lazy_relationship_hash(normalized[:execution])
            normalized = Fields::Internal.frozen_owned_copy(normalized) if freeze_sections
            new(
              normalized,
              lineage: lineage,
              freeze_sections: freeze_sections
            )
          end

          def from_record(record, freeze_sections: true)
            Record.validate_normalized!(record)
            from_normalized_hash(record.to_h, lineage: record.lineage, freeze_sections: freeze_sections)
          end
        end

        LINEAGE_IDENTITY_KEYS = %i[type id depth root parent].freeze
        private_constant :LINEAGE_IDENTITY_KEYS

        BuildOptions = Data.define(:fields_owned, :input_owned, :freeze_sections, :error_backtrace_lines) do
          class << self
            def defensive(freeze_sections:, error_backtrace_lines:)
              return default_defensive.fetch(freeze_sections) if default_backtrace_lines?(error_backtrace_lines)

              new(false, false, freeze_sections, error_backtrace_lines)
            end

            def pipeline_owned(input_owned:, freeze_sections:, error_backtrace_lines:)
              if default_backtrace_lines?(error_backtrace_lines)
                return default_pipeline.fetch(input_owned).fetch(freeze_sections)
              end

              new(true, input_owned, freeze_sections, error_backtrace_lines)
            end

            private

            def default_backtrace_lines?(value)
              value == Core::MAX_BACKTRACE_LINES
            end

            def default_defensive
              # Hot-path defaults are reused by every emitted record.
              @default_defensive ||= {
                false => new(false, false, false, Core::MAX_BACKTRACE_LINES),
                true => new(false, false, true, Core::MAX_BACKTRACE_LINES)
              }.freeze
            end

            def default_pipeline
              @default_pipeline ||= {
                false => {
                  false => new(true, false, false, Core::MAX_BACKTRACE_LINES),
                  true => new(true, false, true, Core::MAX_BACKTRACE_LINES)
                }.freeze,
                true => {
                  false => new(true, true, false, Core::MAX_BACKTRACE_LINES),
                  true => new(true, true, true, Core::MAX_BACKTRACE_LINES)
                }.freeze
              }.freeze
            end
          end
        end
        private_constant :BuildOptions

        def initialize(data, lineage: nil, freeze_sections: true)
          @data = data
          @freeze_sections = freeze_sections
          @lineage = lineage || Execution::Lineage.from_execution_hash(@data[:execution])
          validate!
        end

        def [](key) = @data[key]

        def []=(key, value)
          @lineage = nil if key == :execution
          ensure_mutable_data!
          @data[key] = value
          @to_record = nil
        end

        def fetch(...) = @data.fetch(...)

        def dig(...) = @data.dig(...)

        def key?(key) = @data.key?(key)

        def each(&) = @data.each(&)

        def each_key(&) = @data.each_key(&)

        def to_h = Fields::FieldSet.deep_dup_owned(@data)

        def transform_field!(key)
          key = Fields::Internal.normalize_key(key)
          replace_transformed_field!(key, yield(@data[key]))
          self
        end

        def transform_section!(key)
          key = Fields::Internal.normalize_key(key)
          section = @data[key]
          replacement = yield(section)
          raise TypeError, "record #{key} must be a Hash" unless replacement.is_a?(Hash)

          replace_transformed_field!(key, replacement)
          self
        end

        def transform_record!
          previous_lineage = @lineage
          previous_identity = execution_lineage_identity(@data[:execution])
          replacement = yield(@data)
          @lineage = replacement_lineage_for(previous_lineage, previous_identity, replacement)
          @data = replacement
          @to_record = nil
          self
        end

        Record::REQUIRED_KEYS.each do |key|
          define_method(key) { @data[key] }
        end

        def validate!
          Record.validate_normalized_hash!(@data)
          self
        end

        def lineage = (@lineage ||= Execution::Lineage.from_execution_hash(@data[:execution]))

        def to_record
          @to_record ||= Record.from_owned_hash(@data, lineage: @lineage, trust_frozen: @freeze_sections)
        end

        private

        def replace_transformed_field!(key, value)
          preserve_lineage = transformed_field_lineage(key, value)
          ensure_mutable_data!
          @data[key] = value
          @lineage = preserve_lineage if key == :execution
          @to_record = nil
        end

        def ensure_mutable_data!
          @data = Fields::FieldSet.deep_dup_owned(@data) if @data.frozen?
        end

        def transformed_field_lineage(key, value)
          return @lineage unless key == :execution

          replacement_lineage_for(
            @lineage,
            execution_lineage_identity(@data[:execution]),
            @data.merge(execution: value)
          )
        end

        def replacement_lineage_for(lineage, previous, data)
          return unless lineage

          current = data.is_a?(Hash) ? execution_lineage_identity(data[:execution]) : nil
          lineage if previous == current
        end

        def execution_lineage_identity(execution)
          return unless execution.is_a?(Hash)

          normalized = Fields::FieldSet.deep_symbolize_keys(execution)
          LINEAGE_IDENTITY_KEYS.each_with_object({}) do |key, identity|
            identity[key] = normalized[key] if normalized.key?(key)
          end
        end

        class BuildInput
          # Normalizes raw emit input into draft top-level fields plus payload.
          RECORD_INPUT_KEYS = Record::REQUIRED_KEYS.freeze
          RECORD_INPUT_KEY_SET = RECORD_INPUT_KEYS.to_h { [it, true] }.freeze
          private_constant :RECORD_INPUT_KEYS
          private_constant :RECORD_INPUT_KEY_SET

          class << self
            def call(input, owned:)
              return {} if input.nil?
              return input if owned && input.is_a?(Hash)
              return shallow_symbolize(input) if RawInput.hash_input?(input)

              { message: input.to_s }
            end

            private

            def shallow_symbolize(input)
              normalized = {}
              payload_fields = {}
              input.each do |key, raw_value|
                normalized_key = Fields::Internal.normalize_key(key)
                value = raw_value.equal?(input) ? CIRCULAR_REFERENCE : raw_value
                if RECORD_INPUT_KEY_SET.key?(normalized_key)
                  normalized[normalized_key] = value
                else
                  payload_fields[normalized_key] = value
                end
              end
              merge_unknown_payload!(normalized, payload_fields)
              normalized
            end

            def merge_unknown_payload!(normalized, payload_fields)
              return if payload_fields.empty?

              normalized[:payload] = if normalized.key?(:payload)
                                       merge_payload_input(normalized[:payload], payload_fields)
                                     else
                                       payload_fields
                                     end
            end

            def merge_payload_input(explicit_payload, unknown_payload)
              if explicit_payload.is_a?(Hash)
                Fields::FieldSet.merge(unknown_payload, explicit_payload)
              else
                Fields::FieldSet.merge(unknown_payload, Fields::FieldSet::VALUE_KEY => explicit_payload)
              end
            end
          end
        end
        private_constant :BuildInput

        class Builder
          EMPTY_HASH = {}.freeze
          private_constant :EMPTY_HASH

          def initialize(input = {}, context:, neutral:, attributes:, carry:, static_labels:, scope:, # rubocop:disable Metrics/ParameterLists
                         invalid_severity_reporter:, options:)
            @input_owned = options.input_owned
            @input = BuildInput.call(input, owned: @input_owned)
            @context = context || {}
            @neutral = neutral || {}
            @attributes = attributes || {}
            @carry = carry || {}
            @static_labels = static_labels || {}
            @fields_owned = options.fields_owned
            @freeze_sections = options.freeze_sections
            @error_backtrace_lines = options.error_backtrace_lines
            @invalid_severity_reporter = invalid_severity_reporter
            @scope = scope
          end

          def to_h
            source = normalized_value(:source)
            event = immutable_scalar_value(event_value.to_s)

            base_record(source, event)
          end

          def lineage
            @lineage ||= @scope&.lineage || Execution::Lineage.from_execution_hash(input_execution_hash)
          end

          private

          def base_record(source, event)
            {
              timestamp: timestamp_value,
              severity: severity_for(source, event),
              kind: kind_for(value(:kind)),
              event: event,
              message: normalized_value(:message),
              logger: normalized_value(:logger),
              source: source,
              execution: execution_hash,
              context: context_hash,
              carry: carry_hash,
              neutral: neutral_hash,
              attributes: attributes_hash,
              labels: labels_hash,
              payload: hash_value(:payload),
              metrics: hash_value(:metrics),
              error: normalize_error(value(:error))
            }
          end

          def event_value
            raw_value = value(:event)
            raw_value.nil? ? "log" : raw_value
          end

          def timestamp_value
            raw_value = value(:timestamp)
            Serialization::ValueCopy.call(raw_value.nil? ? Time.now.utc : raw_value, freeze_values: true)
          end

          def severity_for(source, event)
            return normalize_record_severity(value(:severity), source: source, event: event) if present?(:severity)

            :info
          end

          def normalize_record_severity(raw_value, source:, event:)
            Records::Severity.normalize(raw_value)
          rescue ArgumentError
            # Below-threshold raw inputs warn before draft construction.
            @invalid_severity_reporter.call(raw_value, source: source, event: event)
            :info
          end

          def kind_for(kind)
            return :point if kind.nil?
            return kind if Record::KINDS.value?(kind)

            Record::KINDS.fetch(kind.to_s) do
              raise ArgumentError, "unsupported record kind: #{kind.inspect}"
            end
          end

          def execution_hash
            return base_execution_hash unless present?(:execution)

            merge_section(scope_execution_hash, :execution)
          end

          def base_execution_hash
            return scope_frozen_execution_hash if owned_frozen_scope_execution?

            normalized_hash(scope_execution_hash)
          end

          def input_execution_hash
            present?(:execution) ? hash_value(:execution) : scope_execution_hash
          end

          def context_hash
            section_hash(@context, :context)
          end

          def carry_hash
            section_hash(@carry, :carry)
          end

          def attributes_hash
            section_hash(@attributes, :attributes)
          end

          def neutral_hash
            section_hash(@neutral, :neutral)
          end

          def labels_hash
            section_hash(labels_base, :labels)
          end

          def merge_section(base, key)
            return merge_owned_section(base, key) if @input_owned

            value = hash_value(key)
            value = Execution::Lineage.clean_execution_hash(value) if key == :execution
            return normalized_hash(value) if base.empty?

            base = Fields::FieldSet.deep_dup(base)
            merged = if key == :attributes
                       Fields::Internal.deep_merge!(base, value)
                     else
                       Fields::FieldSet.merge!(base, value)
                     end
            normalized_hash(merged)
          end

          def merge_owned_section(base, key)
            value = hash_value(key)
            value = clean_owned_execution_hash(value) if key == :execution
            return normalized_hash(value) if base.empty?

            base = Fields::FieldSet.deep_dup(base)
            merged = if key == :attributes
                       Fields::Internal.deep_merge_owned!(base, value)
                     else
                       Fields::Internal.merge_owned!(base, value)
                     end
            normalized_hash(merged)
          end

          def clean_owned_execution_hash(value)
            return Execution::Lineage.clean_execution_hash(value) if @freeze_sections

            Execution::Lineage.clean_owned_execution_hash(value)
          end

          def section_hash(base, key)
            return base if owned_frozen_section?(base) && !present?(key)
            return normalized_hash(base) unless present?(key)

            merge_section(base, key)
          end

          def owned_frozen_section?(base)
            @fields_owned && @freeze_sections && base.is_a?(Hash) && base.frozen?
          end

          def owned_frozen_scope_execution?
            @scope && @fields_owned && @freeze_sections
          end

          def labels_base
            return scope_labels_hash if @static_labels.empty?

            Fields::FieldSet.merge!(Fields::FieldSet.deep_dup(@static_labels), scope_labels_hash)
          end

          def hash_value(key)
            return empty_hash unless present?(key)

            raw_value = value(key)
            return normalized_hash(raw_value) if raw_value.is_a?(Hash)

            normalized_hash(Fields::FieldSet::VALUE_KEY => raw_value)
          end

          def value(key)
            @input[key]
          end

          def normalized_value(key)
            immutable_scalar_value(value(key))
          end

          def immutable_scalar_value(value)
            return value unless value.is_a?(String)
            return value if value.frozen?
            return value.dup unless @freeze_sections
            return value.freeze if @input_owned

            value.dup.freeze
          end

          def present?(key)
            @input.key?(key)
          end

          def normalize_error(error)
            case error
            when nil
              nil
            when Exception
              normalized_hash(Serialization::ExceptionShape.call(error, max_backtrace_lines: @error_backtrace_lines))
            when Hash
              normalized_hash(normalize_error_hash(error))
            else
              normalized_hash(message: error.to_s)
            end
          end

          def normalize_error_hash(error)
            Serialization::BacktraceLimiter.call(
              Fields::FieldSet.deep_symbolize_keys(error),
              max_backtrace_lines: @error_backtrace_lines
            )
          end

          def normalized_hash(value)
            return empty_hash if value.is_a?(Hash) && value.empty?

            if @input_owned
              return Fields::Internal.frozen_deep_symbolize_owned_keys(value) if @freeze_sections
              return value if value.is_a?(Hash)

              return Fields::FieldSet.deep_symbolize_owned_keys(value)
            end
            return Fields::Internal.frozen_deep_symbolize_keys(value) if @freeze_sections

            Fields::FieldSet.deep_symbolize_keys(value)
          end

          def empty_hash
            @freeze_sections ? EMPTY_HASH : {}
          end

          def scope_execution_hash = @scope ? @scope.frozen_execution_hash : EMPTY_HASH

          def scope_frozen_execution_hash = @scope.frozen_execution_hash

          def scope_labels_hash = @scope ? @scope.frozen_labels_hash : EMPTY_HASH
        end
        private_constant :Builder
      end
    end
  end
end
