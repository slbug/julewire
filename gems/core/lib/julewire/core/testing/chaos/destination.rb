# frozen_string_literal: true

module Julewire
  module Core
    module Testing
      module Chaos
        module Destination
          class << self
            def assert_contract(test_context, record:, formatter:, encoder:, output:, callbacks:, errors:)
              {
                formatter: formatter,
                encoder: encoder,
                output: output,
                callbacks: callbacks
              }.compact.each do |scenario, builder|
                assert_scenario(test_context, scenario, builder, record, errors)
              end
              nil
            end

            private

            def assert_scenario(test_context, scenario, builder, record, errors)
              errors.each do |error|
                assert_error_contained(test_context, scenario, builder, record, error)
              end
              nil
            end

            def assert_error_contained(test_context, scenario, builder, record, error)
              Chaos.assert_contained(
                test_context,
                errors: [error],
                description: "destination #{scenario}"
              ) do |build_error|
                destination = builder.call(build_error)
                destination.emit(record)
              ensure
                close_destination(destination)
              end
            end

            def close_destination(destination)
              return unless destination.respond_to?(:close)

              destination.close(timeout: 0)
            rescue StandardError
              nil
            end
          end
        end
      end
    end
  end
end
