# frozen_string_literal: true

module Julewire
  module Core
    module Diagnostics
      class Doctor
        class << self
          def call(runtime)
            new(runtime).call
          end
        end

        def initialize(runtime)
          @runtime = runtime
        end

        def call
          health = @runtime.health
          config = @runtime.config
          {
            status: health.fetch(:status),
            runtime: runtime_info(health, config),
            pipeline: pipeline_info(health.fetch(:pipeline)),
            integrations: integration_info(health.fetch(:integrations)),
            process_integrations: integration_info(health.fetch(:process_integrations)),
            warnings: warnings(health)
          }
        end

        private

        def runtime_info(health, config)
          {
            closed: health.fetch(:closed),
            counts: health.fetch(:counts),
            generation: health.fetch(:generation),
            level: config.level,
            last_failure: health[:last_failure],
            status: health.fetch(:status)
          }
        end

        def pipeline_info(pipeline)
          {
            configured: pipeline.fetch(:configured),
            counts: pipeline.fetch(:counts),
            destinations: destination_info(pipeline.fetch(:destinations)),
            last_failure: pipeline[:last_failure],
            status: pipeline.fetch(:status)
          }
        end

        def destination_info(destinations)
          destinations.transform_values do |destination|
            component_info(destination, include_loss: true)
          end
        end

        def integration_info(integrations)
          integrations.transform_values do |integration|
            component_info(integration)
          end
        end

        def component_info(component, include_loss: false)
          {
            counts: component[:counts],
            last_failure: component[:last_failure],
            last_loss: include_loss ? component[:last_loss] : nil,
            status: component[:status]
          }.compact
        end

        def warnings(health)
          [].tap do |items|
            items << warning(:runtime_closed, "runtime is closed") if health.fetch(:closed)
            pipeline_warnings(health.fetch(:pipeline), items)
            integration_warnings(health.fetch(:integrations), items, label: :integration)
            integration_warnings(health.fetch(:process_integrations), items, label: :process_integration)
          end
        end

        def pipeline_warnings(pipeline, items)
          items << warning(:no_destinations, "pipeline has no destinations") unless pipeline.fetch(:configured)
          if pipeline.fetch(:configured) && pipeline.fetch(:status) != :ok
            items << warning(:pipeline_degraded, "pipeline is #{pipeline.fetch(:status)}")
          end
          component_warnings(
            pipeline.fetch(:destinations),
            items,
            code: :destination_degraded,
            label: :destination
          )
        end

        def integration_warnings(integrations, items, label:)
          component_warnings(integrations, items, code: :integration_degraded, label: label)
        end

        def component_warnings(components, items, code:, label:)
          components.each do |name, component|
            next if component[:status] == :ok

            items << warning(code, "#{label} #{name} is #{component[:status]}")
          end
        end

        def warning(code, message)
          { code: code, message: message }.freeze
        end
      end
    end
  end
end
