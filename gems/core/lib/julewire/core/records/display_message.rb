# frozen_string_literal: true

module Julewire
  module Core
    module Records
      class DisplayMessage
        class << self
          def call(record)
            error = value_at(record, :error)
            metrics = value_at(record, :metrics)
            neutral = value_at(record, :neutral)

            explicit_message(record) || neutral_message(neutral, error, metrics) || error_summary(error)
          end

          def error_summary(error)
            error = hash_error(error)

            error_class = value_at(error, :class)
            error_message = value_at(error, :message)
            error_class = nil if blank?(error_class)
            error_message = nil if blank?(error_message)
            return unless error_class || error_message
            return error_message.to_s unless error_class
            return error_class.to_s unless error_message

            "#{error_class}: #{error_message}"
          end

          private

          def explicit_message(record)
            message = value_at(record, :message)
            message unless blank?(message)
          end

          def neutral_message(neutral, error, metrics)
            http_message(neutral, error, metrics) ||
              job_message(neutral, error, metrics) ||
              messaging_message(neutral, error, metrics) ||
              source_location_message(neutral)
          end

          def http_message(neutral, error, metrics)
            method = neutral_value(neutral, Fields::AttributeKeys::HTTP_REQUEST_METHOD)
            path = neutral_value(neutral, Fields::AttributeKeys::URL_PATH) ||
                   neutral_value(neutral, Fields::AttributeKeys::URL_FULL)
            status = neutral_value(neutral, Fields::AttributeKeys::HTTP_RESPONSE_STATUS_CODE)
            return if blank?(method) || blank?(path) || blank?(status)

            message = "#{method} #{path} -> #{status}"
            append_part(message, error_class(error))
            append_part(message, duration(metrics))
          end

          def job_message(neutral, error, metrics)
            system = neutral_value(neutral, Fields::AttributeKeys::JOB_SYSTEM)
            name = neutral_value(neutral, Fields::AttributeKeys::JOB_NAME)
            id = neutral_value(neutral, Fields::AttributeKeys::JOB_ID)
            status = neutral_value(neutral, Fields::AttributeKeys::JOB_STATUS)
            return if blank?(system) && blank?(name) && blank?(id)

            message = phrase(system || "job", name || id)
            append_part(message, key_value("queue", job_queue(neutral)))
            append_part(message, status_phrase(status, error, metrics))
          end

          def messaging_message(neutral, error, metrics)
            system = neutral_value(neutral, Fields::AttributeKeys::MESSAGING_SYSTEM)
            operation = neutral_value(neutral, Fields::AttributeKeys::MESSAGING_OPERATION_NAME)
            destination = neutral_value(neutral, Fields::AttributeKeys::MESSAGING_DESTINATION_NAME)
            return if blank?(system) && blank?(operation) && blank?(destination)

            message = phrase(system || "messaging", operation)
            append_part(message, destination)
            append_part(message, key_value(
                                   "partition",
                                   neutral_value(neutral, Fields::AttributeKeys::MESSAGING_DESTINATION_PARTITION_ID)
                                 ))
            append_part(message, key_value("offset", neutral_value(neutral, Fields::AttributeKeys::MESSAGING_KAFKA_OFFSET)))
            append_part(message, key_value(
                                   "messages",
                                   neutral_value(neutral, Fields::AttributeKeys::MESSAGING_BATCH_MESSAGE_COUNT)
                                 ))
            append_part(message, error_class(error))
            append_part(message, duration(metrics))
          end

          def source_location_message(neutral)
            file = neutral_value(neutral, Fields::AttributeKeys::CODE_FILE_PATH)
            return if blank?(file)

            line = neutral_value(neutral, Fields::AttributeKeys::CODE_LINE_NUMBER)
            function = neutral_value(neutral, Fields::AttributeKeys::CODE_FUNCTION_NAME)
            message = line ? "#{file}:#{line}" : file.to_s.dup
            append_part(message, function)
          end

          def status_phrase(status, error, metrics)
            message = append_part(nil, status)
            message = append_part(message, error_class(error))
            message = append_part(message, duration(metrics))
            return unless message

            "-> #{message}"
          end

          def error_class(error)
            value_at(hash_error(error), :class)
          end

          def duration(metrics)
            duration_ms = value_at(metrics, :duration_ms)
            "in #{duration_text(Float(duration_ms))}ms"
          rescue ArgumentError, TypeError
            nil
          end

          def duration_text(value)
            text = format("%.3f", value.round(3))
            text.delete_suffix!("0") while text.end_with?("0")
            text.delete_suffix!(".")
            text
          end

          def job_queue(neutral)
            neutral_value(neutral, Fields::AttributeKeys::JOB_QUEUE_NAME)
          end

          def hash_error(error)
            error if error.is_a?(Hash)
          end

          def neutral_value(neutral, key)
            value_at(neutral, key)
          end

          def key_value(name, value)
            "#{name}=#{value}" unless blank?(value)
          end

          def phrase(first, second)
            message = first.to_s.dup
            append_part(message, second)
          end

          def append_part(message, part)
            return message if blank?(part)

            return part.to_s.dup unless message

            message << " " << part.to_s
          end

          def value_at(value, key)
            Fields::Lookup.value(value, key)
          end

          def blank?(value)
            Fields::Lookup.blank?(value)
          end
        end
      end
    end
  end
end
