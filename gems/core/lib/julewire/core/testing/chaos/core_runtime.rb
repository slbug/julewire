# frozen_string_literal: true

module Julewire
  module Core
    module Testing
      module Chaos
        module CoreRuntime
          SCENARIOS = %i[
            destination_processor
            drop_callback
            encoder
            failure_callback
            formatter
            lifecycle_after_fork
            lifecycle_flush
            output
            pipeline_processor
          ].freeze

          private_constant :SCENARIOS

          class << self
            def assert_contract(test_context, runtime:, reset:, errors:)
              SCENARIOS.each do |scenario|
                errors.each do |error|
                  assert_scenario(test_context, runtime, reset, scenario, error)
                end
              end
              nil
            end

            private

            def assert_scenario(test_context, runtime, reset, scenario, error)
              reset.call
              send(:"exercise_#{scenario}", runtime, error)
            rescue StandardError => e
              test_context.flunk(
                "expected core #{scenario} failure to be contained, " \
                "#{error.class} leaked #{e.class}: #{e.message}"
              )
            ensure
              reset.call
            end

            def exercise_destination_processor(runtime, error)
              configure_destination(runtime, processors: [Chaos.raiser(error)])
              runtime.emit("chaos")
            end

            def exercise_drop_callback(runtime, error)
              trigger = RuntimeError.new("julewire chaos formatter trigger")
              configure_destination(runtime, formatter: Chaos.raiser(trigger), on_drop: Chaos.raiser(error))
              runtime.emit("chaos")
            end

            def exercise_encoder(runtime, error)
              configure_destination(runtime, encoder: Chaos.raiser(error))
              runtime.emit("chaos")
            end

            def exercise_failure_callback(runtime, error)
              trigger = RuntimeError.new("julewire chaos output trigger")
              configure_destination(
                runtime,
                output: RaisingOutput.new(trigger, failures: %i[write]),
                runtime_on_failure: Chaos.raiser(error)
              )
              runtime.emit("chaos")
            end

            def exercise_formatter(runtime, error)
              configure_destination(runtime, formatter: Chaos.raiser(error))
              runtime.emit("chaos")
            end

            def exercise_lifecycle_after_fork(runtime, error)
              configure_destination(runtime, output: RaisingOutput.new(error, failures: %i[after_fork]))
              runtime.after_fork!
            end

            def exercise_lifecycle_flush(runtime, error)
              configure_destination(runtime, output: RaisingOutput.new(error, failures: %i[flush]))
              runtime.flush
            end

            def exercise_output(runtime, error)
              configure_destination(runtime, output: RaisingOutput.new(error, failures: %i[write]))
              runtime.emit("chaos")
            end

            def exercise_pipeline_processor(runtime, error)
              runtime.configure do |config|
                config.destinations.use(:default, output: NullOutput.new)
                config.processors.use(Chaos.raiser(error))
              end
              runtime.emit("chaos")
            end

            def configure_destination(runtime, output: NullOutput.new, formatter: nil, encoder: nil,
                                      on_drop: nil, processors: nil, runtime_on_failure: nil)
              runtime.configure do |config|
                config.on_failure = runtime_on_failure if runtime_on_failure
                config.destinations.clear
                config.destinations.use(
                  :default,
                  encoder: encoder || Julewire::Core::Serialization::JsonEncoder.new,
                  formatter: formatter || Julewire::Core::Records::Formatter.new,
                  on_drop: on_drop,
                  output: output,
                  processors: processors || []
                )
              end
            end
          end
        end
      end
    end
  end
end
