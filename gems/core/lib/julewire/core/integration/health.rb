# frozen_string_literal: true

module Julewire
  module Core
    module Integration
      # @api integration_spi
      module Health
        class << self
          def record_failure(integration, error, runtime: nil, **metadata)
            if runtime
              runtime.record_integration_failure(integration, error, **metadata)
            else
              Diagnostics::ProcessIntegrationHealth.record_failure(integration, error, **metadata)
            end
            nil
          end

          def record_success(integration, runtime: nil, **)
            if runtime
              runtime.record_integration_success(integration)
            else
              Diagnostics::ProcessIntegrationHealth.record_success(integration)
            end
            nil
          end

          def with_failure_health(integration, component:, action:, runtime: nil, **metadata)
            yield.tap { record_success(integration, runtime: runtime) }
          rescue StandardError => e
            record_failure(integration, e, runtime: runtime, component: component, action: action, **metadata)
            nil
          end

          def scoped(integration, runtime: nil)
            Scoped.new(integration, runtime: runtime)
          end
        end
      end
    end
  end
end
