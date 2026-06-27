# frozen_string_literal: true

require "concurrent/atomic/atomic_reference"

module Julewire
  module Core
    module Diagnostics
      class Tail
        DEFAULT_CAPACITY = 200
        DEFAULT_NAME = :tail
        COUNTER_KEYS = %i[captured failures].freeze
        Entry = Data.define(:sequence, :at, :record)
        State = Data.define(:sequence, :items)
        EMPTY_ENTRIES = [].freeze
        private_constant :State, :EMPTY_ENTRIES

        class << self
          def attach!(runtime = Julewire, **)
            destination = new(**)
            runtime.configure { it.destinations.add(destination) }
            destination
          end
        end

        attr_reader :capacity, :name

        def initialize(
          name: DEFAULT_NAME,
          capacity: DEFAULT_CAPACITY,
          formatter: Records::Formatter.new,
          renderer: Renderer.new,
          serializer: nil
        )
          @name = Core.normalize_name(name)
          @capacity = Validation.validate_integer_limit!(capacity, name: :capacity, positive: true)
          Validation.validate_callable!(formatter, name: :formatter)
          Validation.validate_callable!(renderer, name: :renderer)
          @formatter = formatter
          @renderer = renderer
          @serializer = serializer
          @serializer_pool_key = :"julewire_core_tail_serializers_#{object_id}"
          initialize_state
        end

        def emit(record)
          snapshot = snapshot_record(record)
          @state_ref.update do |state|
            sequence = state.sequence + 1
            entries = (state.items + [Entry.new(sequence, Time.now.utc, snapshot)]).last(@capacity)
            State.new(sequence, entries)
          end
          @health.increment(:captured)
          nil
        rescue StandardError => e
          record_failure(e, record)
          nil
        end

        def entries(limit: nil)
          limit = normalize_limit(limit)
          snapshot = @state_ref.get.items.dup
          limit ? snapshot.last(limit) : snapshot
        end

        def records(limit: nil)
          entries(limit: limit).map(&:record)
        end

        def render(limit: nil, color: false)
          @renderer.call(entries(limit: limit), color: color)
        end

        def write(io = $stdout, limit: nil, color: nil)
          io.write(render(limit: limit, color: color.nil? ? io.tty? : color))
          io
        end

        def clear
          @state_ref.update { State.new(it.sequence, EMPTY_ENTRIES) }
          @health.clear_failures!
          self
        end

        def flush(*) = self

        def close(*) = self

        def after_fork!
          initialize_state
          self
        end

        def health
          @health.snapshot(capacity: @capacity, size: entries.length)
        end

        private

        def initialize_state
          @state_ref = Concurrent::AtomicReference.new(State.new(0, EMPTY_ENTRIES))
          @health = Integration::DestinationHealth.new(counter_keys: COUNTER_KEYS)
          @serializer_mutex = Mutex.new
        end

        def normalize_limit(value)
          return if value.nil?

          Validation.validate_integer_limit!(value, name: :limit, positive: true)
        end

        def snapshot_record(record)
          payload = @formatter.call(record)
          raise TypeError, "formatter must return a payload object" if payload.nil?

          Serialization::DeepFreeze.call(with_display_message(serialize_payload(payload), record))
        end

        def with_display_message(payload, record)
          return payload unless payload.is_a?(Hash)
          return payload unless blank?(payload["message"]) && blank?(payload[:message])

          message = Records::DisplayMessage.call(record)
          return payload if blank?(message)

          payload = payload.dup
          payload["message"] = message
          payload
        end

        def serialize_payload(payload)
          return serialize_custom_payload(payload) if @serializer

          Serialization::SerializerPool.serialize_with(cached_serializer, payload) { build_serializer }
        end

        def serialize_custom_payload(payload)
          @serializer_mutex.synchronize { @serializer.serialize(payload) }
        end

        def cached_serializer
          Serialization::SerializerPool.serializer(@serializer_pool_key, nil) { build_serializer }
        end

        def build_serializer
          Serializer.new(compact_empty: true)
        end

        def blank?(value)
          value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end

        def record_failure(error, record)
          @health.record_failure(
            error,
            action: :emit,
            destination: @name,
            phase: :tail,
            record_metadata: Records::Metadata.call(record)
          )
        end
      end
    end
  end
end
