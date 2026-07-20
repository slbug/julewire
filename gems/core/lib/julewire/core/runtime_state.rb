# frozen_string_literal: true

module Julewire
  module Core
    RuntimeState = Data.define(
      :configuration,
      :pipeline,
      :pipeline_closed,
      :pipeline_generation
    )

    class RuntimeState
      class << self
        def default
          configuration = Configuration.new.snapshot
          pipeline = configuration.build_pipeline

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
