# frozen_string_literal: true

module Julewire
  module Core
    module Testing
      module Contracts
        module Wire
          def assert_julewire_propagation_contract(key: Julewire::Core::Propagation::Carrier::DEFAULT_KEY)
            carrier = {}
            extracted = nil
            restored = nil

            Julewire.with_execution(type: :contract, id: "contract-1", emit_summary: false) do
              Julewire.context.add(request_id: "request-1")
              Julewire.carry.add(http: { request_headers: { traceparent: contract_traceparent } })

              assert_same carrier, Julewire::Core::Propagation::Carrier.inject(carrier, key: key)

              extracted = Julewire::Core::Propagation::Carrier.extract(carrier, key: key)
              assert_equal "request-1", extracted.dig(:context, :request_id)
              assert_equal contract_traceparent, extracted.dig(:carry, :http, :request_headers, :traceparent)
              assert_equal "contract-1", extracted.dig(:execution, :id)

              Julewire::Core::Propagation::Carrier.restore(carrier, key: key) do
                restored = Julewire::Core::Propagation.capture_local
              end
            end

            assert_equal "request-1", restored.dig(:context, :request_id)
            assert_equal contract_traceparent, restored.dig(:carry, :http, :request_headers, :traceparent)
            assert_equal "contract-1", restored.dig(:execution, :id)
            assert_oversize_carrier_clears_stale_value!(key)

            extracted
          end

          private

          def assert_oversize_carrier_clears_stale_value!(key)
            string_key = key.to_s
            symbol_key = key.is_a?(String) ? key.to_sym : key
            carrier = { string_key => "stale" }
            carrier[symbol_key] = "stale" if symbol_key != string_key

            result = Julewire::Core::Propagation::Carrier.inject(
              carrier,
              envelope: { context: { large: "x" * 64 } },
              key: key,
              max_bytes: 1
            )

            assert_nil result
            refute carrier.key?(string_key)
            refute carrier.key?(symbol_key) if symbol_key != string_key
          end
        end
      end
    end
  end
end
