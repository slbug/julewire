# frozen_string_literal: true

module Julewire
  module Karafka
    class Configuration
      IMPORTANT_CONSUMER_EVENT_NAMES = %w[
        app.initialized
        app.running
        app.quiet
        app.stopped
        consumer.consumed
        consumer.revoked
        consumer.shutdown
        dead_letter_queue.dispatched
        filtering.throttled
        rebalance.partitions_assigned
        rebalance.partitions_revoked
        swarm.node.after_fork
        worker.completed
        error.occurred
      ].freeze

      IMPORTANT_PRODUCER_EVENT_NAMES = %w[
        producer.connected
        producer.closed
        message.produced_async
        message.produced_sync
        message.acknowledged
        messages.produced_async
        messages.produced_sync
        transaction.committed
        transaction.aborted
        buffer.flushed_async
        buffer.flushed_sync
        error.occurred
      ].freeze

      include Julewire::Core::Integration::Settings

      setting :enabled, default: true, predicate: true
      setting :consumer_events, default: true, predicate: true
      setting :producer_events, default: true, predicate: true
      setting :propagation, default: true, predicate: true
      setting :carrier_filter
      setting :carrier_key, default: Julewire::Core::Propagation::Carrier::DEFAULT_KEY
      setting :carrier_max_bytes, validate: byte_limit
      setting :source, default: "karafka"
      setting :consumer_event_names, default: :important
      setting :producer_event_names, default: :important
    end
  end
end
