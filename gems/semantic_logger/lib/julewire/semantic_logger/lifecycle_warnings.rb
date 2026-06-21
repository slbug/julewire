# frozen_string_literal: true

module Julewire
  module SemanticLogger
    module LifecycleWarnings
      class << self
        def call(async:, appender_count:, max_queue_size:)
          if async && max_queue_size == -1
            [{ reason: :async_queue_unbounded }]
          elsif async
            [{ reason: :async_queue_blocks_when_full, max_queue_size: max_queue_size }]
          elsif appender_count > 1
            [{ reason: :sync_multi_appender_blocks_emitters, appender_count: appender_count }]
          else
            []
          end
        end
      end
    end
  end
end
