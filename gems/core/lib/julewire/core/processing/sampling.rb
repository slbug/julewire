# frozen_string_literal: true

module Julewire
  module Core
    module Processing
      # @api extension
      module Sampling
        HASH_SPACE = 1 << 64
        FNV_OFFSET = 14_695_981_039_346_656_037
        FNV_PRIME = 1_099_511_628_211
        HASH_MASK = HASH_SPACE - 1
        MIX_ONE = 0xff51afd7ed558ccd
        MIX_TWO = 0xc4ceb9fe1a85ec53
        private_constant :FNV_OFFSET, :FNV_PRIME, :HASH_MASK, :HASH_SPACE, :MIX_ONE, :MIX_TWO

        class << self
          def head(rate:, key: nil)
            Head.new(rate: rate, key: key)
          end

          def keep?(rate:, key:)
            threshold = threshold_for(rate)
            return false if key.nil?

            stable_hash(key) < threshold
          end

          def threshold_for(rate)
            raise ArgumentError, "rate must be a finite Numeric between 0 and 1" unless valid_rate?(rate)

            (rate * HASH_SPACE).floor
          end

          def stable_hash(value)
            hash = key_string(value).each_byte.reduce(FNV_OFFSET) do |hash, byte|
              ((hash ^ byte) * FNV_PRIME) & HASH_MASK
            end
            mix_hash(hash)
          end

          private

          def valid_rate?(rate)
            rate.between?(0, 1)
          rescue StandardError
            false
          end

          def mix_hash(hash)
            hash ^= hash >> 33
            hash = (hash * MIX_ONE) & HASH_MASK
            hash ^= hash >> 33
            hash = (hash * MIX_TWO) & HASH_MASK
            hash ^ (hash >> 33)
          end

          def key_string(value)
            case value
            when String then value
            when Symbol then value.name
            else value.inspect
            end
          end
        end

        class Head
          def initialize(rate:, key:)
            @threshold = Sampling.threshold_for(rate)
            @key = key
            Validation.validate_callable!(key, name: :key, allow_nil: true)
          end

          def call(draft)
            return :drop if @threshold.zero?

            value = key_for(draft)
            return :drop if value.nil?
            return if @threshold == HASH_SPACE

            Sampling.stable_hash(value) < @threshold ? nil : :drop
          end

          private

          def key_for(draft)
            @key ? @key.call(draft) : default_key(draft)
          end

          def default_key(draft)
            root_id(draft) ||
              field_value(draft[:execution], :id) ||
              field_value(draft[:context], :request_id) ||
              [draft[:source], draft[:event], draft[:message]].join("\0")
          end

          def root_id(draft)
            field_value(draft.lineage.root_reference, :id) if draft.respond_to?(:lineage)
          end

          def field_value(hash, key)
            return unless hash.is_a?(Hash)

            Fields::FieldSet.value_for(hash, key)
          end
        end
      end
    end
  end
end
