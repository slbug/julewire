# frozen_string_literal: true

module Julewire
  module ActiveJob
    module JobSerialization
      CONFIGURATION_METHOD = :julewire_active_job_configuration

      def serialize
        super.tap do |job_data|
          inject_julewire_carrier(job_data)
        end
      end

      def deserialize(job_data)
        extract_julewire_carrier(job_data)
        super
      end

      private

      def inject_julewire_carrier(job_data)
        configuration = julewire_active_job_configuration
        return unless configuration.propagation?

        value = serialized_carrier_value(configuration)
        return unless value

        job_data[configuration.serialized_carrier_key] = value
        IntegrationHealth.record_success
      rescue StandardError => e
        IntegrationHealth.record_failure(e, action: :carrier_inject, component: :job_serialization)
      end

      def serialized_carrier_value(configuration)
        # A deserialized job retains its enqueue origin, not the reserializer's context.
        carrier = instance_variable_get(CARRIER_IVAR)
        return Core::Propagation::Carrier.encode(max_bytes: configuration.carrier_max_bytes) unless carrier

        value = carrier[configuration.carrier_key]
        return unless value
        return value unless configuration.carrier_max_bytes

        value if value.bytesize <= configuration.carrier_max_bytes
      end

      def extract_julewire_carrier(job_data)
        configuration = julewire_active_job_configuration
        unless configuration.propagation?
          instance_variable_set(CARRIER_IVAR, {})
          return
        end

        value = job_data[configuration.serialized_carrier_key]
        value = value.to_s if value
        instance_variable_set(CARRIER_IVAR, value ? { configuration.carrier_key => value } : {})
        IntegrationHealth.record_success
      rescue StandardError => e
        IntegrationHealth.record_failure(e, action: :carrier_extract, component: :job_serialization)
        instance_variable_set(CARRIER_IVAR, {})
      end

      def julewire_active_job_configuration
        self.class.public_send(CONFIGURATION_METHOD)
      rescue StandardError
        ActiveJob.config
      end
    end
  end
end
