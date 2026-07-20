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
            input = nil,
            context:,
            scope:,
            attributes: nil,
            neutral: nil,
            carry: nil,
            static_labels: nil,
            error_backtrace_lines: DEFAULT_ERROR_BACKTRACE_LINES,
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
              fields_owned: false,
              input_owned: false,
              error_backtrace_lines: error_backtrace_lines
            )
          end

          def build_pipeline_owned( # rubocop:disable Metrics/ParameterLists -- Record construction has fixed public sections.
            input,
            context:,
            scope:,
            attributes: nil,
            neutral: nil,
            carry: nil,
            input_owned: false,
            error_backtrace_lines: DEFAULT_ERROR_BACKTRACE_LINES,
            invalid_severity_reporter: Diagnostics::InvalidSeverityReporter
          )
            build_with(
              input,
              context: context,
              neutral: neutral,
              attributes: attributes,
              carry: carry,
              static_labels: nil,
              scope: scope,
              invalid_severity_reporter: invalid_severity_reporter,
              fields_owned: true,
              input_owned: input_owned,
              error_backtrace_lines: error_backtrace_lines
            )
          end

          private

          def build_with(input, context:, neutral:, attributes:, carry:, static_labels:, scope:, # rubocop:disable Metrics/ParameterLists
                         invalid_severity_reporter:, fields_owned:, input_owned:,
                         error_backtrace_lines:)
            builder = Builder.new(
              input,
              context: context,
              neutral: neutral,
              attributes: attributes,
              carry: carry,
              static_labels: static_labels,
              scope: scope,
              invalid_severity_reporter: invalid_severity_reporter,
              fields_owned: fields_owned,
              input_owned: input_owned,
              error_backtrace_lines: error_backtrace_lines
            )
            new(builder.to_h, lineage: builder.lineage)
          end

          public

          def from_normalized_hash(data, lineage: nil)
            Record.validate_normalized_hash!(data)
            normalized = Fields::FieldSet.deep_dup_owned(data)
            execution = normalized.fetch(:execution)
            lineage ||= Execution::Lineage.from_execution_hash(execution)
            normalized[:execution] = Execution::Lineage.clean_normalized_lazy_relationship_hash(execution)
            new(normalized, lineage: lineage)
          end

          def from_record(record)
            Record.validate_normalized!(record)
            from_normalized_hash(record.to_h, lineage: record.lineage)
          end
        end
        private_class_method :new

        DEFAULT_ERROR_BACKTRACE_LINES = Core::MAX_BACKTRACE_LINES
        LINEAGE_IDENTITY_KEYS = %i[type id depth root parent].freeze
        private_constant :DEFAULT_ERROR_BACKTRACE_LINES, :LINEAGE_IDENTITY_KEYS

        def initialize(data, lineage:)
          @data = data
          @lineage = lineage
        end

        def [](key) = @data[key]

        def []=(key, value)
          @data[key] = value
          @lineage = nil if key == :execution
        end

        def fetch(...) = @data.fetch(...)

        def dig(...) = @data.dig(...)

        def key?(key) = @data.key?(key)

        def each(&) = @data.each(&)

        def each_key(&) = @data.each_key(&)

        def to_h = Fields::FieldSet.deep_dup_owned(@data)

        def transform_field!(key)
          ensure_unfinalized!
          validate_transform_key!(key, Record::REQUIRED_KEYS, kind: :field)
          replace_transformed_field!(key, yield(self[key]))
          self
        end

        def transform_section!(key)
          ensure_unfinalized!
          validate_transform_key!(key, Record::HASH_SECTIONS, kind: :section)
          section = self[key]
          replacement = yield(section)
          raise TypeError, "record #{key} must be a Hash" unless replacement.is_a?(Hash)

          replace_transformed_field!(key, replacement)
          self
        end

        def transform_record!
          ensure_unfinalized!
          previous_lineage = @lineage
          previous_identity = execution_lineage_identity(fetch(:execution))
          replacement = yield(@data)
          @lineage = replacement_lineage_for(previous_lineage, previous_identity, replacement)
          @data = replacement.dup
          self
        end

        Record::REQUIRED_KEYS.each do |key|
          define_method(key) { @data[key] }
        end

        def validate!
          Record.validate_normalized_hash!(@data)
          self
        end

        def lineage = (@lineage ||= Execution::Lineage.from_execution_hash(fetch(:execution)))

        def to_record
          return @to_record if @to_record

          record = Record.from_owned_hash(@data, lineage: @lineage)
          @lineage = record.lineage
          @to_record = record
          freeze
          record
        end

        private

        def validate_transform_key!(key, allowed, kind:)
          raise TypeError, "record transform #{kind} must be a Symbol" unless key.instance_of?(Symbol)
          return if allowed.include?(key)

          raise ArgumentError, "unknown record #{kind}: #{key}"
        end

        def replace_transformed_field!(key, value)
          if key == :execution
            replace_transformed_execution!(value)
          else
            self[key] = value
          end
        end

        def replace_transformed_execution!(value)
          preserve_lineage = transformed_execution_lineage(value)
          self[:execution] = value
          @lineage = preserve_lineage
        end

        def ensure_unfinalized!
          raise FrozenError, "can't transform a finalized record draft" if frozen?
        end

        def transformed_execution_lineage(value)
          replacement_lineage_for(
            @lineage,
            execution_lineage_identity(fetch(:execution)),
            @data.merge(execution: value)
          )
        end

        def replacement_lineage_for(lineage, previous, data)
          current = execution_lineage_identity(data[:execution]) if data.is_a?(Hash)
          lineage if previous == current
        end

        def execution_lineage_identity(execution)
          return unless execution.is_a?(Hash)

          LINEAGE_IDENTITY_KEYS.each_with_object({}) do |key, identity|
            identity[key] = execution.fetch(key) if execution.key?(key)
          end
        end

        class Builder
          EMPTY_HASH = {}.freeze
          private_constant :EMPTY_HASH

          def initialize(input, context:, neutral:, attributes:, carry:, static_labels:, scope:, # rubocop:disable Metrics/ParameterLists
                         invalid_severity_reporter:, fields_owned:, input_owned:,
                         error_backtrace_lines:)
            @input_owned = input_owned
            @input = if @input_owned
                       BuildInput.validate_owned(input)
                     else
                       BuildInput.normalize_public(input)
                     end
            @context = context || {}
            @neutral = neutral || {}
            @attributes = attributes || {}
            @carry = carry || {}
            @static_labels = static_labels || {}
            @fields_owned = fields_owned
            @error_backtrace_lines = error_backtrace_lines
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
              severity: severity_value,
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

          def severity_value
            return normalize_record_severity(value(:severity)) if present?(:severity)

            :info
          end

          def normalize_record_severity(raw_value)
            Severity.normalize(raw_value)
          rescue ArgumentError
            # Below-threshold raw inputs warn before draft construction.
            @invalid_severity_reporter.call(raw_value)
            :info
          end

          def kind_for(kind)
            return :point if kind.nil?

            Record::KINDS.fetch(kind.to_s) do
              raise ArgumentError, "unsupported record kind: #{kind.inspect}"
            end
          end

          def execution_hash
            return base_execution_hash unless present?(:execution)

            merge_section(scope_execution_hash, :execution)
          end

          def base_execution_hash
            normalized_hash(scope_execution_hash, owned: true)
          end

          def input_execution_hash
            hash_value(:execution)
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
            section_hash(@static_labels.merge(scope_labels_hash || EMPTY_HASH), :labels)
          end

          def merge_section(base, key)
            value = hash_value(key)
            value = clean_owned_execution_hash(value) if key == :execution

            target = normalized_hash(base, owned: @fields_owned)
            if key == :attributes
              Fields::Internal.deep_merge_owned!(target, value)
            else
              Fields::Internal.merge_owned!(target, value)
            end
          end

          def clean_owned_execution_hash(value)
            Execution::Lineage.clean_owned_execution_hash(value)
          end

          def section_hash(base, key) = merge_section(base, key)

          def hash_value(key)
            return {} unless present?(key)

            raw_value = value(key)
            return normalized_input_hash(raw_value) if raw_value.is_a?(Hash)

            normalized_input_hash(Fields::FieldSet::VALUE_KEY => raw_value)
          end

          def value(key)
            @input[key]
          end

          def normalized_value(key)
            immutable_scalar_value(value(key))
          end

          def immutable_scalar_value(value)
            return value unless value.is_a?(String)

            value.dup
          end

          def present?(key)
            @input.key?(key)
          end

          def normalize_error(error)
            case error
            when nil
              nil
            when Exception
              Serialization::ExceptionShape.call(error, max_backtrace_lines: @error_backtrace_lines)
            when Hash
              normalize_error_hash(error)
            else
              { message: immutable_scalar_value(error.to_s) }
            end
          end

          def normalize_error_hash(error)
            Serialization::BacktraceLimiter.call(
              mutable_input_hash(error),
              max_backtrace_lines: @error_backtrace_lines
            )
          end

          def normalized_input_hash(value)
            normalized_hash(value, owned: @input_owned)
          end

          def normalized_hash(value, owned:)
            return Fields::FieldSet.deep_dup_owned(value) if owned

            Fields::FieldSet.deep_symbolize_keys(value)
          end

          def mutable_input_hash(value)
            if @input_owned
              Fields::FieldSet.deep_dup_owned(value)
            else
              Fields::FieldSet.deep_symbolize_keys(value)
            end
          end

          def scope_execution_hash = @scope ? @scope.frozen_execution_hash : EMPTY_HASH

          def scope_labels_hash = @scope&.frozen_labels_hash
        end
        private_constant :Builder
      end
    end
  end
end
