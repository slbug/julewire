# frozen_string_literal: true

module Julewire
  module Core
    module Integration
      # @api integration_spi
      module Lifecycle
        class << self
          def require_optional(path)
            require path
          rescue LoadError
            nil
          end

          def register_after_fork(integration, component:, &)
            ForkHooks.register(integration, component: component, &)
          end
        end
      end
    end
  end
end
