# frozen_string_literal: true

module Julewire
  module Core
    # @api bridge_spi
    # Runtime swapping exists for concurrency bridges and integration tests.
    # Application code should prefer the top-level Julewire facade.
    module RuntimeLocator
      class << self
        def current
          LocalStorage.runtime
        end

        def current=(runtime)
          LocalStorage.runtime = runtime
        end
      end
    end
  end
end
