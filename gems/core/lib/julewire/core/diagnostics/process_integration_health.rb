# frozen_string_literal: true

module Julewire
  module Core
    module Diagnostics
      module ProcessIntegrationHealth
        @store = IntegrationHealthStore.new

        class << self
          def record_failure(...) = @store.record_failure(...)

          def record_success(...) = @store.record_success(...)

          def health = @store.health

          def reset! = @store.reset!

          def after_fork!
            @store = IntegrationHealthStore.new
            nil
          end
        end
      end
    end
  end
end
