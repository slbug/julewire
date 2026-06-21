# frozen_string_literal: true

module Julewire
  module SemanticLogger
    module AppenderHealth
      class << self
        def call(value, index: nil)
          {
            appender_class: value.class.name,
            index: index,
            type: appender_type(value)
          }.compact
            .merge(async_health(value))
            .merge(file_health(value))
            .merge(collection_health(value))
        end

        def appender_type(value)
          case value
          when ::SemanticLogger::Appender::Async
            "async"
          when ::SemanticLogger::Appenders
            "multi_appender"
          when ::SemanticLogger::Appender::File
            "file"
          when ::SemanticLogger::Appender::IO
            "io"
          else
            "appender"
          end
        end

        def async_health(value)
          return {} unless value.is_a?(::SemanticLogger::Appender::Async)

          {
            active: value.active?,
            capped: value.capped?,
            max_queue_size: value.max_queue_size,
            queue_size: value.queue.size,
            wrapped: call(value.appender)
          }
        end

        def file_health(value)
          return {} unless value.is_a?(::SemanticLogger::Appender::File)

          {
            current_file_name: value.current_file_name,
            file_name: value.file_name,
            log_count: value.log_count,
            log_size: value.log_size,
            reopen_at: value.reopen_at&.utc&.iso8601
          }
        end

        def collection_health(value)
          return {} unless value.is_a?(::SemanticLogger::Appenders)

          {
            appender_count: value.length,
            appenders: value.each_with_index.map { |child, index| call(child, index: index) }
          }
        end
      end
    end
  end
end
