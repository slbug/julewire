# frozen_string_literal: true
# shareable_constant_value: literal

module Julewire
  module Core
    module Fields
      # @api integration_spi
      module AttributeKeys
        HTTP_REQUEST_METHOD = :"http.request.method"
        HTTP_RESPONSE_BODY_SIZE = :"http.response.body.size"
        HTTP_RESPONSE_STATUS_CODE = :"http.response.status_code"
        URL_FULL = :"url.full"
        URL_PATH = :"url.path"
        USER_AGENT_ORIGINAL = :"user_agent.original"
        CLIENT_ADDRESS = :"client.address"

        CODE_FILE_PATH = :"code.file.path"
        CODE_FUNCTION_NAME = :"code.function.name"
        CODE_LINE_NUMBER = :"code.line.number"

        MESSAGING_BATCH_MESSAGE_COUNT = :"messaging.batch.message_count"
        MESSAGING_CONSUMER_GROUP_NAME = :"messaging.consumer.group.name"
        MESSAGING_DESTINATION_NAME = :"messaging.destination.name"
        MESSAGING_DESTINATION_PARTITION_ID = :"messaging.destination.partition.id"
        MESSAGING_KAFKA_MESSAGE_KEY = :"messaging.kafka.message.key"
        MESSAGING_KAFKA_OFFSET = :"messaging.kafka.offset"
        MESSAGING_OPERATION_NAME = :"messaging.operation.name"
        MESSAGING_OPERATION_TYPE = :"messaging.operation.type"
        MESSAGING_SYSTEM = :"messaging.system"

        JOB_ENQUEUED_AT = :"job.enqueued_at"
        JOB_EXECUTION_COUNT = :"job.execution_count"
        JOB_ID = :"job.id"
        JOB_NAME = :"job.name"
        JOB_PRIORITY = :"job.priority"
        JOB_PROVIDER_ID = :"job.provider_id"
        JOB_QUEUE_NAME = :"job.queue.name"
        JOB_SCHEDULED_AT = :"job.scheduled_at"
        JOB_STATUS = :"job.status"
        JOB_SYSTEM = :"job.system"

        class << self
          def fields(fields)
            return {} unless fields.is_a?(Hash)

            fields.compact
          end

          def from(neutral) = neutral.is_a?(Hash) ? neutral : {}
        end
      end
    end
  end
end
