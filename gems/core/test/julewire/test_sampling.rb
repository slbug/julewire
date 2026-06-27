# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestSampling < Minitest::Test
    cover Julewire::Sampling
    cover Julewire::Core::Processing::Sampling
    cover "Julewire::Core::Processing::ProcessorChain*"
    def test_head_sampler_keeps_all_at_rate_one
      sampler = Julewire::Sampling.head(rate: 1)

      assert_nil sampler.call(draft_for("same-key"))
    end

    def test_head_sampler_drops_all_at_rate_zero
      sampler = Julewire::Sampling.head(rate: 0)

      assert_equal :drop, sampler.call(draft_for("same-key"))
    end

    def test_head_sampler_rate_zero_drops_without_reading_key
      sampler = Julewire::Sampling.head(rate: 0, key: ->(_draft) { raise "key should not be read" })

      assert_equal :drop, sampler.call(draft_for("same-key"))
    end

    def test_head_sampler_rate_one_keeps_without_hashing_key
      opaque_key = Object.new
      def opaque_key.inspect = raise("key should not be hashed")
      sampler = Julewire::Sampling.head(rate: 1, key: ->(_draft) { opaque_key })

      assert_nil sampler.call(draft_for("same-key"))
    end

    def test_head_sampler_is_deterministic_for_custom_keys
      sampler = Julewire::Sampling.head(rate: 0.5, key: ->(draft) { draft.dig(:context, :request_id) })
      first = sample_decisions(sampler)
      second = sample_decisions(sampler)

      assert_equal first, second
      assert_includes first.values, nil
      assert_includes first.values, :drop
    end

    def test_head_sampler_uses_default_stable_execution_key
      sampler = Julewire::Sampling.head(rate: 0.5)
      first = sampler.call(draft_for("ignored", execution: { type: :request, id: "exec-1" }))
      second = sampler.call(draft_for("different-message", execution: { type: :request, id: "exec-1" }))

      assert_equal first, second
    end

    def test_head_sampler_default_key_prefers_lineage_root_id
      sampler = Julewire::Sampling.head(rate: 0.5)
      draft = Julewire::RecordDraft.build(
        {
          execution: {
            type: "job",
            id: "request-2",
            root: { type: "request", id: "root-1" },
            depth: 2
          },
          message: "sampled"
        },
        context: { request_id: "request-2" },
        scope: nil
      )

      assert_equal :drop, sampler.call(draft)
    end

    def test_head_sampler_default_key_prefers_execution_id_without_lineage
      sampler = Julewire::Sampling.head(rate: 0.5)
      draft = hash_draft(
        execution: { type: :request, id: "request-1" },
        context: { request_id: "request-2" },
        message: "sampled"
      )

      assert_equal :drop, sampler.call(draft)
    end

    def test_head_sampler_default_key_prefers_context_request_id_without_execution_id
      sampler = Julewire::Sampling.head(rate: 0.5)
      draft = hash_draft(
        execution: {},
        context: { request_id: "request-2" },
        message: "different-message"
      )

      assert_nil sampler.call(draft)
    end

    def test_head_sampler_default_key_falls_back_to_source_event_and_message
      sampler = Julewire::Sampling.head(rate: 0.5)

      assert_nil sampler.call(hash_draft(execution: {}, context: {}, message: "sampled"))
      assert_equal :drop, sampler.call(hash_draft(execution: {}, context: {}, message: "different-message"))
    end

    def test_head_sampler_default_key_tolerates_sparse_hash_like_drafts
      sampler = Julewire::Sampling.head(rate: 1)

      assert_nil sampler.call({})
    end

    def test_head_sampler_default_fallback_includes_each_record_identity_field
      assert_fallback_field_affects_decision(
        hash_draft(execution: {}, context: {}, source: "source-a"),
        hash_draft(execution: {}, context: {}, source: "source-b")
      )
      assert_fallback_field_affects_decision(
        hash_draft(execution: {}, context: {}, event: "event-a"),
        hash_draft(execution: {}, context: {}, event: "event-b")
      )
      assert_fallback_field_affects_decision(
        hash_draft(execution: {}, context: {}, message: "message-a"),
        hash_draft(execution: {}, context: {}, message: "message-b")
      )
    end

    def test_head_sampler_drops_nil_custom_keys
      sampler = Julewire::Sampling.head(rate: 1, key: ->(_draft) {})

      assert_equal :drop, sampler.call(draft_for("same-key"))
    end

    def test_head_sampler_accepts_hash_like_drafts_without_lineage
      sampler = Julewire::Sampling.head(rate: 1)
      draft = {
        context: { request_id: "request-1" },
        event: "sample.event",
        execution: {},
        message: "sampled",
        source: :test
      }

      assert_nil sampler.call(draft)
    end

    def test_keep_handles_edge_rates_and_nil_keys
      assert_false Julewire::Sampling.keep?(rate: 0, key: "request-1")
      assert_true Julewire::Sampling.keep?(rate: 1, key: "request-1")
      assert_false Julewire::Sampling.keep?(rate: 1, key: nil)
      assert_false Julewire::Sampling.keep?(rate: 0.5, key: nil)
    end

    def test_keep_uses_stable_hash_threshold
      assert_false Julewire::Sampling.keep?(rate: 0.5, key: "request-1")
      assert_true Julewire::Sampling.keep?(rate: 0.5, key: "request-2")
      assert_false Julewire::Sampling.keep?(rate: 0.5, key: "alpha")
    end

    def test_threshold_for_edge_and_midpoint_rates
      assert_equal 0, Julewire::Sampling.threshold_for(0)
      assert_equal 0, Julewire::Sampling.threshold_for(1e-20)
      assert_equal 9_223_372_036_854_775_808, Julewire::Sampling.threshold_for(0.5)
      assert_equal 5_534_023_222_112_865_280, Julewire::Sampling.threshold_for(0.3)
      assert_instance_of Integer, Julewire::Sampling.threshold_for(0.3)
      assert_equal 18_446_744_073_709_551_616, Julewire::Sampling.threshold_for(1)
    end

    def test_threshold_rejects_invalid_rates
      [nil, -0.1, 1.1, Float::NAN, Float::INFINITY, "0.5", Object.new].each do |rate|
        assert_raises_message(ArgumentError, "rate must be a finite Numeric between 0 and 1") do
          Julewire::Sampling.threshold_for(rate)
        end
      end
    end

    def test_stable_hash_normalizes_symbols_and_accepts_other_keys
      assert_equal Julewire::Sampling.stable_hash("request_one"), Julewire::Sampling.stable_hash(:request_one)
      assert_kind_of Integer, Julewire::Sampling.stable_hash(Object.new)
    end

    def test_stable_hash_has_golden_values
      stable_object = Object.new
      stable_object.define_singleton_method(:inspect) { "stable-object" }

      assert_equal 15_568_773_575_654_238_526, Julewire::Sampling.stable_hash("request-1")
      assert_equal 3_571_186_615_877_086_748, Julewire::Sampling.stable_hash("request-2")
      assert_equal 16_254_264_051_188_190_400, Julewire::Sampling.stable_hash(:request_one)
      assert_equal 4_154_356_544_277_223_590, Julewire::Sampling.stable_hash(stable_object)
    end

    def test_head_sampler_validates_rate_and_key
      assert_raises_message(ArgumentError, "rate must be a finite Numeric between 0 and 1") do
        Julewire::Sampling.head(rate: 1.1)
      end
      assert_raises_message(ArgumentError, "key must respond to #call") do
        Julewire::Sampling.head(rate: 0.5, key: :request_id)
      end
    end

    def test_sampling_processor_counts_pipeline_drops
      output = StringIO.new
      sampler = Julewire::Sampling.head(rate: 0)
      pipeline = build_pipeline(output: output, processors: [sampler])

      pipeline.emit(message: "sampled")

      assert_empty output.string
      assert_equal 1, pipeline.health.dig(:counts, :processor_dropped)
    end

    private

    def sample_decisions(sampler)
      (1..512).to_h do |index|
        key = "request-#{index}"
        [key, sampler.call(draft_for(key))]
      end
    end

    def draft_for(request_id, execution: {})
      Julewire::RecordDraft.build(
        { execution: execution, message: "sampled" },
        context: { request_id: request_id },
        scope: nil
      )
    end

    def hash_draft(execution:, context:, source: :test, event: "sample.event", message: "sampled")
      {
        context: context,
        event: event,
        execution: execution,
        message: message,
        source: source
      }
    end

    def assert_fallback_field_affects_decision(first, second)
      first_key = fallback_key(first)
      second_key = fallback_key(second)
      rate = split_rate(first_key, second_key)
      sampler = Julewire::Sampling.head(rate: rate)

      assert_sample_decision sample_decision(first_key, rate), sampler.call(first)
      assert_sample_decision sample_decision(second_key, rate), sampler.call(second)
      refute_equal sampler.call(first), sampler.call(second)
    end

    def fallback_key(draft)
      [draft[:source], draft[:event], draft[:message]].join("\0")
    end

    def split_rate(first_key, second_key)
      first_hash = Julewire::Sampling.stable_hash(first_key)
      second_hash = Julewire::Sampling.stable_hash(second_key)
      lower, upper = [first_hash, second_hash].minmax

      Rational(lower + ((upper - lower) / 2), 1 << 64)
    end

    def sample_decision(key, rate)
      Julewire::Sampling.keep?(rate: rate, key: key) ? nil : :drop
    end

    def assert_sample_decision(expected, actual)
      return assert_nil(actual) if expected.nil?

      assert_equal expected, actual
    end
  end
end
