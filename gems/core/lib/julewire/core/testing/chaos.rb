# frozen_string_literal: true

module Julewire
  module Core
    module Testing
      # @api extension
      module Chaos
        DEFAULT_ERRORS = [
          RuntimeError.new("julewire chaos runtime"),
          ArgumentError.new("julewire chaos argument"),
          TypeError.new("julewire chaos type")
        ].freeze
        class << self
          def assert_contained(test_context, errors: DEFAULT_ERRORS, description: nil)
            raise ArgumentError, "block required" unless block_given?

            errors.each do |error|
              yield error
            rescue StandardError => e
              test_context.flunk(containment_message(description, error, e))
            end
            nil
          end

          def assert_core_runtime_containment(test_context, runtime: Julewire, reset: nil, errors: DEFAULT_ERRORS)
            reset ||= -> { runtime.reset! }
            raise ArgumentError, "reset must respond to call" unless reset.respond_to?(:call)

            CoreRuntime.assert_contract(test_context, runtime: runtime, reset: reset, errors: errors)
          end

          def catalog(&)
            Catalog.build(&)
          end

          def assert_discovered_chaos_contracts(test_context, catalog:, errors: DEFAULT_ERRORS)
            Catalog.assert_contract(test_context, catalog: catalog, errors: errors)
          end

          def assert_destination_chaos_contract(test_context, record:, formatter:, encoder:, output:,
                                                callbacks: nil, errors: DEFAULT_ERRORS)
            Destination.assert_contract(
              test_context,
              record: record,
              formatter: formatter,
              encoder: encoder,
              output: output,
              callbacks: callbacks,
              errors: errors
            )
          end

          def assert_emitter_chaos_contract(test_context, component:, build:, exercise:, errors: DEFAULT_ERRORS)
            Emitter.assert_contract(
              test_context,
              component: component,
              build: build,
              exercise: exercise,
              errors: errors
            )
          end

          def raiser(error = RuntimeError.new("julewire chaos"))
            ->(*) { raise error }
          end

          private

          def containment_message(description, expected_error, leaked_error)
            unless description
              return "expected #{expected_error.class} to be contained, leaked #{leaked_error.class}: #{leaked_error}"
            end

            "expected #{description} chaos to be contained, leaked #{leaked_error.class}: #{leaked_error}"
          end
        end
      end
    end
  end
end
