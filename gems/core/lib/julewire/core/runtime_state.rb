# frozen_string_literal: true

module Julewire
  module Core
    RuntimeState = Data.define(
      :configuration,
      :pipeline,
      :pipeline_closed,
      :pipeline_generation
    ) do
      class << self
        def default(invalid_severity_reporter: Diagnostics::InvalidSeverityReporter.counter)
          configuration = Configuration.new.snapshot
          pipeline = configuration.build_pipeline(invalid_severity_reporter: invalid_severity_reporter)

          new(
            configuration: configuration,
            pipeline: pipeline,
            pipeline_closed: false,
            pipeline_generation: 0
          )
        end
      end

      def closed
        with(pipeline_closed: true)
      end

      def next_generation(configuration:, pipeline:)
        self.class.new(
          configuration: configuration,
          pipeline: pipeline,
          pipeline_closed: false,
          pipeline_generation: pipeline_generation + 1
        )
      end
    end
  end
end
