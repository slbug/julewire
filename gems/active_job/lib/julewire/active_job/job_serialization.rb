# frozen_string_literal: true

module Julewire
  module ActiveJob
    module JobSerialization
      CONFIGURATION_IVAR = :@julewire_active_job_configuration
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

        carrier = Julewire::Core::Propagation::Carrier.inject(
          {},
          key: configuration.carrier_key,
          max_bytes: configuration.carrier_max_bytes
        )
        return unless carrier

        value = carrier[configuration.carrier_key.to_s]
        job_data[configuration.serialized_carrier_key] = value if value
        IntegrationHealth.record_success(action: :carrier_inject, component: :job_serialization)
      rescue StandardError => e
        IntegrationHealth.record_failure(e, action: :carrier_inject, component: :job_serialization)
      end

      def extract_julewire_carrier(job_data)
        configuration = julewire_active_job_configuration
        unless configuration.propagation?
          instance_variable_set(CARRIER_IVAR, {})
          return
        end

        value = job_data[configuration.serialized_carrier_key]
        instance_variable_set(CARRIER_IVAR, value ? { configuration.carrier_key => value } : {})
        IntegrationHealth.record_success(action: :carrier_extract, component: :job_serialization)
      rescue StandardError => e
        IntegrationHealth.record_failure(e, action: :carrier_extract, component: :job_serialization)
        instance_variable_set(CARRIER_IVAR, {})
      end

      def julewire_active_job_configuration
        if self.class.respond_to?(CONFIGURATION_METHOD)
          configuration = self.class.public_send(CONFIGURATION_METHOD)
          return configuration if configuration
        end

        self.class.ancestors.each do |ancestor|
          next unless ancestor.instance_variable_defined?(CONFIGURATION_IVAR)

          return ancestor.instance_variable_get(CONFIGURATION_IVAR)
        end
        Julewire::ActiveJob.config
      rescue StandardError
        Julewire::ActiveJob.config
      end
    end
  end
end
