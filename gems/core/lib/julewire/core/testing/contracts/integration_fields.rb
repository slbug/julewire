# frozen_string_literal: true

module Julewire
  module Core
    module Testing
      module Contracts
        module IntegrationFields
          private

          def assert_julewire_integration_field_overlay_contract
            records = Julewire::Core::Testing.capture(snapshot: true) do
              Julewire.with_execution(type: :contract, emit_summary: false) do
                Julewire::Core::Integration::Facade.add_context(contract_context: "ctx")
                Julewire::Core::Integration::Facade.add_carry(contract_carry: "carry")
                Julewire::Core::Integration::Facade.add_attributes(contract_attribute: "attr")
                Julewire::Core::Integration::Facade.add_neutral("contract.neutral": "neutral")
                Julewire.emit(event: "contract.spi", source: "contract")
              end
              Julewire.flush
            end

            record = records.find { it[:event] == "contract.spi" }
            flunk("expected integration field overlay contract record") unless record

            assert_equal "ctx", record.dig(:context, :contract_context)
            assert_equal "carry", record.dig(:carry, :contract_carry)
            assert_equal "attr", record.dig(:attributes, :contract_attribute)
            assert_equal "neutral", record.dig(:neutral, :"contract.neutral")
          ensure
            Julewire.reset!
          end
        end
      end
    end
  end
end
