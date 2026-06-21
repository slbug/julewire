# frozen_string_literal: true

module Julewire
  module Core
    module Testing
      module Contracts
        module Runtime
          def assert_julewire_runtime_integration_contract(**options)
            run_julewire_runtime_contract(options)
          end

          def assert_julewire_execution_boundary_contract(**options)
            run_julewire_execution_boundary_contract(options)
          end

          def assert_julewire_failure_containment_contract(configure:, destination_name: :default, emit: nil)
            Julewire.configure(&configure)

            assert_nil((emit || default_failure_contract_emit).call)

            health = Julewire.health
            destination_health = health.dig(:pipeline, :destinations, destination_name.to_sym)

            assert_equal :degraded, health.fetch(:status)
            assert_kind_of Hash, destination_health

            [health, destination_health]
          end

          def assert_julewire_record_source_contract(
            records:,
            event:,
            source:,
            **options
          )
            record = find_contract_record(records, options.fetch(:event_path, %w[event]), event)

            assert_equal source.to_s, fetch_contract_path(record, options.fetch(:source_path, %w[source])).to_s
            assert_contract_optional_source_field(record, options, :logger)
            assert_contract_optional_source_field(record, options, :kind)

            record
          end

          private

          def assert_contract_optional_source_field(record, options, field)
            expected = options[field]
            return unless expected

            path = options.fetch(:"#{field}_path", [field.to_s])
            assert_equal expected.to_s, fetch_contract_path(record, path).to_s
          end

          def run_julewire_runtime_contract(options)
            Julewire.configure(&options.fetch(:configure))
            emit_runtime_contract_records

            records = options.fetch(:records).call
            point = find_contract_record(records, options.fetch(:event_path), point_event(options))
            summary = find_contract_record(records, options.fetch(:event_path), summary_event(options))
            health = Julewire.health

            assert_runtime_contract_records(point, summary, health, options)
            [point, summary, health]
          end

          def run_julewire_execution_boundary_contract(options)
            Julewire.configure(&options.fetch(:configure))
            options.fetch(:exercise).call(**execution_boundary_probe(options))
            Julewire.flush

            records = options.fetch(:records).call
            point = find_contract_record(records, options.fetch(:event_path), point_event(options))
            summary = find_contract_record(records, options.fetch(:event_path), summary_event(options))
            health = Julewire.health

            assert_runtime_contract_records(point, summary, health, options)
            [point, summary, health]
          end

          def emit_runtime_contract_records
            Julewire.with_execution(
              type: :contract,
              id: "contract-1",
              summary_event: "contract.completed",
              summary_source: "contract"
            ) do
              Julewire.context.add(request_id: "request-1")
              Julewire.carry.add(http: { request_headers: { traceparent: contract_traceparent } })
              Julewire.summary.add(total: 2)
              Julewire.emit(event: point_event({}), source: "contract", message: "point", payload: { value: 1 })
            end
            Julewire.flush
          end

          def assert_runtime_contract_records(point, summary, health, options)
            assert_equal "request-1", fetch_contract_path(point, options.fetch(:context_path) + [:request_id])
            assert_equal 2, fetch_contract_path(summary, options.fetch(:summary_payload_path) + [:total])
            assert_runtime_contract_carry(point, options[:carry_path]) if options[:carry_path]

            assert health.dig(:pipeline, :configured)
            assert_kind_of Hash, health.dig(:pipeline, :destinations, contract_destination_name(options))
          end

          def assert_runtime_contract_carry(point, carry_path)
            path = carry_path + %i[http request_headers traceparent]

            assert_equal contract_traceparent, fetch_contract_path(point, path)
          end

          def contract_destination_name(options)
            options.fetch(:destination_name, :default).to_sym
          end

          def default_failure_contract_emit
            lambda do
              Julewire.emit(
                event: "contract.failure",
                source: "contract",
                message: "failure probe",
                payload: { token: "secret" }
              )
            end
          end

          def execution_boundary_probe(options)
            {
              add_summary: -> { Julewire.summary.add(total: 2) },
              carry: { http: { request_headers: { traceparent: contract_traceparent } } },
              context: { request_id: "request-1" },
              emit_point: lambda do
                Julewire.emit(event: point_event(options), source: "contract", message: "point", payload: { value: 1 })
              end,
              summary_event: summary_event(options),
              traceparent: contract_traceparent
            }
          end

          def point_event(options)
            options.fetch(:point_event, "contract.point")
          end

          def summary_event(options)
            options.fetch(:summary_event, "contract.completed")
          end

          def find_contract_record(records, event_path, event)
            record = records.find { fetch_contract_path(it, event_path) == event }
            return record if record

            flunk("expected contract record #{event.inspect}, got #{records.inspect}")
          end

          def fetch_contract_path(value, path)
            path.reduce(value) { |current, key| fetch_contract_key(current, key) }
          end

          def fetch_contract_key(value, key)
            return value.fetch(key) if value.respond_to?(:key?) && value.key?(key)
            return value.fetch(key.to_s) if value.respond_to?(:key?) && value.key?(key.to_s)
            return fetch_symbol_contract_key(value, key) if key.respond_to?(:to_sym)

            flunk("expected key #{key.inspect} in #{value.inspect}")
          end

          def fetch_symbol_contract_key(value, key)
            return value.fetch(key.to_sym) if value.respond_to?(:key?) && value.key?(key.to_sym)

            flunk("expected key #{key.inspect} in #{value.inspect}")
          end

          def contract_traceparent = "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01"
        end
      end
    end
  end
end
