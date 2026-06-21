# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestSampling < Minitest::Test
    cover Julewire::Core::Processing::Sampling

    def test_head_sampler_keeps_all_at_rate_one
      sampler = Julewire::Sampling.head(rate: 1)

      assert_nil sampler.call(draft_for("same-key"))
    end

    def test_head_sampler_drops_all_at_rate_zero
      sampler = Julewire::Sampling.head(rate: 0)

      assert_equal :drop, sampler.call(draft_for("same-key"))
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
      refute Julewire::Sampling.keep?(rate: 0, key: "request-1")
      assert Julewire::Sampling.keep?(rate: 1, key: "request-1")
      refute Julewire::Sampling.keep?(rate: 1, key: nil)
      refute Julewire::Sampling.keep?(rate: 0.5, key: nil)
    end

    def test_keep_uses_stable_hash_threshold
      refute Julewire::Sampling.keep?(rate: 0.5, key: "request-1")
      assert Julewire::Sampling.keep?(rate: 0.5, key: "request-2")
      refute Julewire::Sampling.keep?(rate: 0.5, key: "alpha")
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
        scope: nil,
        freeze_sections: false
      )
    end
  end
end
