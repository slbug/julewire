# frozen_string_literal: true

require "json"

module Julewire
  module Core
    module Testing
      module Contracts
        module Component
          def assert_julewire_processor_contract(processor, draft: build_julewire_contract_draft)
            assert_respond_to processor, :call

            result = processor.call(draft)
            return :drop if result == :drop

            result = draft unless result.is_a?(Julewire::Core::Records::Draft)
            result.to_record
            result
          end

          def assert_julewire_formatter_contract(formatter, record: build_julewire_contract_record)
            assert_respond_to formatter, :call

            formatted = formatter.call(record)
            encoded = Julewire::Core::Serialization::JsonEncoder.new.call(formatted)

            assert_kind_of String, encoded
            formatted
          end

          def assert_julewire_destination_contract(destination, record: build_julewire_contract_record)
            %i[name emit flush close health].each do |method_name|
              assert_respond_to destination, method_name
            end

            assert_nil destination.emit(record)
            assert destination.flush(timeout: 0)
            assert destination.close(timeout: 0)
            assert_kind_of Hash, destination.health
            destination
          end

          def assert_julewire_record_shape_contract(record: build_julewire_shape_contract_record)
            Julewire::Core::Records::Record.validate_normalized!(record)

            data = record.to_h
            assert_julewire_record_data_shape!(record, data)
            assert_julewire_record_formatter_shape!(record)
            assert_julewire_record_serializer_shape!(record)

            record
          end

          def build_julewire_contract_record(fields = {})
            build_julewire_contract_draft(fields).to_record
          end

          def build_julewire_contract_draft(fields = {})
            Julewire::Core::Records::Draft.build(
              {
                severity: :info,
                kind: :point,
                event: "test.event",
                source: "test",
                message: "test message",
                attributes: { "test.attribute" => "value" },
                payload: { value: 1 }
              }.merge(fields),
              context: {},
              scope: nil,
              freeze_sections: false
            )
          end

          private

          def assert_julewire_record_data_shape!(record, data)
            assert_julewire_symbol_keys!(data)
            assert_equal(
              Julewire::Core::Records::Record::REQUIRED_KEYS,
              data.keys & Julewire::Core::Records::Record::REQUIRED_KEYS
            )
            assert record.frozen?
            assert record.serializable_data.frozen?
            refute data.fetch(:execution).key?(:ancestors)
            refute data.fetch(:execution).key?(:ancestors_truncated)
            assert_equal [{ type: :request, id: "root-1" }], record.lineage.ancestors
            assert_equal "root-1", record.lineage.root_reference[:id]
          end

          def assert_julewire_record_formatter_shape!(record)
            formatted = Julewire::Core::Serialization::Serializer.call(
              Julewire::Core::Records::Formatter.new.call(record),
              compact_empty: true
            )
            refute formatted.key?("carry")
            assert_equal "visible", formatted.dig("execution", "custom")
            %w[root parent ancestors depth ancestors_truncated].each do |key|
              refute formatted.fetch("execution").key?(key)
            end
          end

          def assert_julewire_record_serializer_shape!(record)
            serialized = Julewire::Core::Serialization::Serializer.call(record)
            assert_equal(
              Julewire::Core::Serialization::ValueCopy::CIRCULAR_REFERENCE,
              serialized.dig("payload", "cycle", "self")
            )
            assert_equal Julewire::Core::Serialization::Serializer::NAN_VALUE, serialized.dig("payload", "nan")
            assert_equal "1.25", serialized.dig("payload", "decimal")
            JSON.generate(serialized, allow_nan: false)
          end

          def build_julewire_shape_contract_record
            cycle = {}
            cycle[:self] = cycle

            build_julewire_contract_record(
              execution: {
                type: :request,
                id: "execution-1",
                root: { type: :request, id: "root-1" },
                parent: { type: :job, id: "parent-1" },
                ancestors: [{ type: :request, id: "root-1" }],
                ancestors_truncated: false,
                depth: 2,
                custom: "visible"
              },
              context: { request_id: "request-1" },
              neutral: Fields::AttributeKeys.fields("http.request.method" => "GET"),
              carry: { http: { request_headers: { traceparent: contract_traceparent } } },
              payload: {
                value: 1,
                nested: { string_key: true },
                cycle: cycle,
                nan: Float::NAN,
                decimal: contract_decimal
              }
            )
          end

          def contract_decimal
            defined?(BigDecimal) ? BigDecimal("1.25") : "1.25"
          end

          def assert_julewire_symbol_keys!(value)
            case value
            when Hash
              assert(
                value.keys.all?(Symbol),
                "expected only symbol keys in #{value.inspect}"
              )
              value.each_value { assert_julewire_symbol_keys!(it) }
            when Array
              value.each { assert_julewire_symbol_keys!(it) }
            end
          end
        end
      end
    end
  end
end
