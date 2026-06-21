# frozen_string_literal: true

module Julewire
  module ActiveJob
    class Configuration
      DEFAULT_SERIALIZED_CARRIER_KEY = "julewire.carrier"

      include Julewire::Core::Integration::Settings

      setting :enabled, default: true, predicate: true
      setting :execution, default: true, predicate: true
      setting :structured_events, default: true, predicate: true
      setting :silence_log_subscriber, default: true, predicate: true
      setting :propagation, default: true, predicate: true
      setting :carrier_key, default: Julewire::Core::Propagation::Carrier::DEFAULT_KEY
      setting :carrier_max_bytes, default: Julewire::Core::Propagation::Carrier::DEFAULT_MAX_BYTES,
                                  validate: byte_limit
      setting :serialized_carrier_key, default: DEFAULT_SERIALIZED_CARRIER_KEY
      setting :source, default: "active_job"
      setting :summary_event, default: "job.completed"
      setting :summary_severity, default: :info
      setting :event_prefixes, default: ["active_job."]
    end
  end
end
