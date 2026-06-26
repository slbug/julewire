# frozen_string_literal: true

require "time"

module Julewire
  module Core
    module Records
      # @api extension
      class Record
        include Enumerable
        include Deconstruct

        KINDS = {
          "point" => :point,
          "summary" => :summary
        }.freeze
        HASH_SECTIONS = Fields::Bags.record_hash_sections
        REQUIRED_KEYS = Fields::Bags.required_record_keys

        class << self
          def from_normalized_hash(record, lineage: nil)
            validate_normalized_hash!(record)
            execution = record.fetch(:execution)
            lineage ||= Execution::Lineage.from_execution_hash(execution)
            record = record.merge(
              execution: Execution::Lineage.clean_normalized_lazy_relationship_hash(execution)
            )
            new(snapshot_hash(record), lineage: lineage)
          end

          def from_owned_hash(record, lineage: nil, trust_frozen: false)
            validate_normalized_hash!(record)
            lineage ||= Execution::Lineage.from_execution_hash(record.fetch(:execution))
            execution = Execution::Lineage.clean_normalized_lazy_relationship_hash(record.fetch(:execution))
            record = record.frozen? ? record.merge(execution: execution) : replace_execution(record, execution)
            new(Serialization::DeepFreeze.call(record, trust_frozen: trust_frozen), lineage: lineage)
          end

          def validate_normalized!(record)
            return record if record.is_a?(self)

            raise TypeError, "expected Julewire::Record"
          end

          def validate_normalized_hash!(record)
            validate_hash!(record)
            record
          end

          private

          def replace_execution(record, execution)
            record[:execution] = execution
            record
          end

          def validate_hash!(record)
            raise TypeError, "record must be a normalized Hash" unless record.is_a?(Hash)

            validate_symbol_keys!(record)

            validate_required_keys!(record)
            validate_known_keys!(record)

            validate_kind!(record.fetch(:kind))
            validate_severity!(record.fetch(:severity))
            validate_hash_sections!(record)
            validate_error!(record.fetch(:error))
          end

          def validate_symbol_keys!(record)
            validate_value_symbol_keys!(record)
          end

          def validate_value_symbol_keys!(root)
            queue = [[root, 0]]
            seen = {}.compare_by_identity

            queue.each do |value, depth|
              break if depth == NORMALIZATION_MAX_DEPTH
              next unless mark_symbol_key_container(value, seen)

              enqueue_symbol_key_children(queue, value, depth + 1)
            end
          end

          def mark_symbol_key_container(value, seen)
            return unless value.is_a?(Hash) || value.is_a?(Array)
            return if seen.key?(value)

            seen[value] = nil
            value
          end

          def enqueue_symbol_key_children(queue, value, depth)
            if value.is_a?(Hash)
              value.each do |key, item|
                raise TypeError, "record must not use string keys" if key.is_a?(String)

                queue << [item, depth]
              end
            else
              value.each { queue << [it, depth] }
            end
          end

          def validate_required_keys!(record)
            missing = nil
            REQUIRED_KEYS.each do |key|
              next if record.key?(key)

              (missing ||= []) << key
            end
            raise TypeError, "record must be complete (missing: #{missing.join(", ")})" if missing
          end

          def validate_known_keys!(record)
            unknown = nil
            record.each_key do |key|
              next if REQUIRED_KEYS.include?(key)

              (unknown ||= []) << key
            end
            return unless unknown

            raise TypeError, "record has unknown top-level keys: #{unknown.join(", ")}"
          end

          def validate_kind!(value)
            return if KINDS.value?(value)

            raise TypeError, "record kind must be :point or :summary"
          end

          def validate_severity!(value)
            return if Severity::VALUES.include?(value)

            raise TypeError, "record severity must be one of: #{Severity::VALUES.join(", ")}"
          end

          def validate_hash_sections!(record)
            HASH_SECTIONS.each do |section|
              next if record.fetch(section).is_a?(Hash)

              raise TypeError, "record #{section} must be a Hash"
            end
          end

          def validate_error!(value)
            return if value.nil? || value.is_a?(Hash)

            raise TypeError, "record error must be nil or a Hash"
          end

          def snapshot_hash(record)
            Serialization::ValueCopy.call(
              record,
              freeze_values: true,
              preserve_truncation_metadata: true
            )
          end
        end

        attr_reader :lineage

        def initialize(data, lineage: nil)
          @data = data
          @lineage = (lineage || Execution::Lineage.from_execution_hash(fetch(:execution))).freeze
          freeze
        end

        def [](key) = @data[key]

        def fetch(...) = @data.fetch(...)

        def dig(...) = @data.dig(...)

        def key?(key) = @data.key?(key)

        def each(&) = @data.each(&)

        def to_h = Fields::FieldSet.deep_dup_owned(@data)

        # @api internal
        def serializable_data = @data

        REQUIRED_KEYS.each do |key|
          define_method(key) { @data[key] }
        end

        def ==(other)
          other.instance_of?(Record) && @data == other.serializable_data
        end

        def eql?(other)
          other.instance_of?(Record) && @data.eql?(other.serializable_data)
        end

        def hash = @data.hash

        def inspect = "#<#{self.class} #{@data}>"
      end
    end
  end
end
