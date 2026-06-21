# frozen_string_literal: true

module Julewire
  module Core
    module Testing
      module Chaos
        module Emitter
          class << self
            def assert_contract(test_context, component:, build:, exercise:, errors:)
              Chaos.assert_contained(test_context, errors: errors, description: component) do |error|
                emitter = build.call(error)
                exercise.call(emitter, error)
              end
            end
          end
        end
      end
    end
  end
end
