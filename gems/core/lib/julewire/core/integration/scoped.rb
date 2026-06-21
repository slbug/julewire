# frozen_string_literal: true

module Julewire
  module Core
    module Integration
      # @api integration_spi
      class Scoped
        def initialize(integration, runtime: nil)
          @integration = integration
          @runtime = runtime
        end

        def record_failure(error, **metadata)
          Health.record_failure(@integration, error, runtime: @runtime, **metadata)
        end

        def record_success(*, **)
          Health.record_success(@integration, runtime: @runtime)
        end

        def with_failure_health(component:, action:, **metadata, &)
          Health.with_failure_health(
            @integration,
            component: component,
            action: action,
            runtime: @runtime,
            **metadata,
            &
          )
        end
      end
    end
  end
end
