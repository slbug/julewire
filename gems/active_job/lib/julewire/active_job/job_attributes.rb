# frozen_string_literal: true
# shareable_constant_value: literal

module Julewire
  module ActiveJob
    module JobAttributes
      JOB_NAME_KEYS = %i[job_class class_name job_name].freeze
      JOB_ID_KEYS = %i[job_id id].freeze
      JOB_PROVIDER_ID_KEYS = %i[provider_job_id].freeze
      JOB_QUEUE_NAME_KEYS = %i[queue queue_name].freeze
      JOB_PRIORITY_KEYS = %i[priority].freeze
      JOB_EXECUTION_COUNT_KEYS = %i[executions].freeze
      JOB_ENQUEUED_AT_KEYS = %i[enqueued_at].freeze
      JOB_SCHEDULED_AT_KEYS = %i[scheduled_at].freeze
      JOB_STATUS_KEYS = %i[status].freeze
      private_constant :JOB_NAME_KEYS
      private_constant :JOB_ID_KEYS
      private_constant :JOB_PROVIDER_ID_KEYS
      private_constant :JOB_QUEUE_NAME_KEYS
      private_constant :JOB_PRIORITY_KEYS
      private_constant :JOB_EXECUTION_COUNT_KEYS
      private_constant :JOB_ENQUEUED_AT_KEYS
      private_constant :JOB_SCHEDULED_AT_KEYS
      private_constant :JOB_STATUS_KEYS

      class << self
        def call(fields)
          Core::Fields::AttributeKeys.fields(
            Core::Fields::AttributeKeys::JOB_SYSTEM => "active_job",
            Core::Fields::AttributeKeys::JOB_NAME => first_value(fields, keys: JOB_NAME_KEYS),
            Core::Fields::AttributeKeys::JOB_ID => first_value(fields, keys: JOB_ID_KEYS),
            Core::Fields::AttributeKeys::JOB_PROVIDER_ID => first_value(fields, keys: JOB_PROVIDER_ID_KEYS),
            Core::Fields::AttributeKeys::JOB_QUEUE_NAME => first_value(fields, keys: JOB_QUEUE_NAME_KEYS),
            Core::Fields::AttributeKeys::JOB_PRIORITY => first_value(fields, keys: JOB_PRIORITY_KEYS),
            Core::Fields::AttributeKeys::JOB_EXECUTION_COUNT => first_value(fields, keys: JOB_EXECUTION_COUNT_KEYS),
            Core::Fields::AttributeKeys::JOB_ENQUEUED_AT => first_value(fields, keys: JOB_ENQUEUED_AT_KEYS),
            Core::Fields::AttributeKeys::JOB_SCHEDULED_AT => first_value(fields, keys: JOB_SCHEDULED_AT_KEYS),
            Core::Fields::AttributeKeys::JOB_STATUS => first_value(fields, keys: JOB_STATUS_KEYS)
          )
        end

        private

        def first_value(fields, keys:)
          Core::Integration::Values::Read.first_value(fields, keys: keys)
        end
      end
    end
  end
end
