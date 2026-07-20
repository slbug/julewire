# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestProcessingMatch < Minitest::Test
    cover Julewire::Match
    cover Julewire::Core::Processing::Match
    def test_on_requires_handler_and_returns_self
      match = Julewire::Match.new

      error = assert_raises(ArgumentError) { match.on(event: "match.ready") }

      assert_equal "match handler is required", error.message
      assert_same match, match.on(event: "match.ready") { :drop }
    end

    def test_call_continues_past_non_matching_and_nil_handlers
      draft = draft_for(event: "match.ready")
      match = Julewire::Match.new do
        on(event: "other") { :drop }
        on(event: "match.ready") { nil }
        on(event: "match.ready") { :drop }
      end

      assert_equal :drop, match.call(draft)
    end

    def test_call_returns_draft_results_and_ignores_other_handler_values
      draft = draft_for(event: "match.ready")
      replacement = draft_for(event: "match.replaced")
      match = Julewire::Match.new do
        on(event: "match.ready") { :ignored }
        on(event: "match.ready") { replacement }
      end

      assert_same replacement, match.call(draft)
    end

    def test_call_accepts_draft_subclass_results
      draft = draft_for(event: "match.ready")
      base_replacement = draft_for(event: "match.replaced")
      replacement_class = Class.new(Core::Records::Draft)
      replacement = replacement_class.send(:new, base_replacement.to_h, lineage: base_replacement.lineage)
      match = Julewire::Match.new do
        on(event: "match.ready") { replacement }
      end

      assert_same replacement, match.call(draft)
    end

    def test_match_supports_proc_regexp_range_module_and_exact_patterns
      error_class = Class.new(StandardError)
      payload = Class.new(Hash).new.merge!(attempts: 2, latency_ms: 42, error: error_class.new("boom"))
      draft = draft_for(event: "job.finished", message: "done")
      draft[:event] = Class.new(String).new("job.finished")
      draft[:payload] = payload
      seen = []
      match = Julewire::Match.new do
        on(
          event: /\Ajob\./,
          message: lambda { |value|
            seen << value
            value == "done"
          },
          payload: {
            attempts: 1..3,
            latency_ms: Integer,
            error: StandardError
          }
        ) { :drop }
      end

      assert_equal :drop, match.call(draft)
      assert_equal ["done"], seen
    end

    def test_match_rejects_negative_pattern_cases_without_raising
      match = Julewire::Match.new do
        on(event: /\Ajob\./, message: String, payload: { attempts: 1..3, latency_ms: Integer }) { :drop }
      end
      numeric_event = draft_for(message: "done", payload: { attempts: 2, latency_ms: 42 })
      numeric_event[:event] = 42

      assert_nil match.call(draft_for(event: "task.finished", message: "done",
                                      payload: { attempts: 2, latency_ms: 42 }))
      assert_nil match.call(numeric_event)
      assert_nil match.call(draft_for(event: "job.finished", message: Object.new,
                                      payload: { attempts: 2, latency_ms: 42 }))
      assert_nil match.call(draft_for(event: "job.finished", message: "done", payload: { attempts: 5, latency_ms: 42 }))
    end

    def test_match_rejects_nested_missing_keys_nil_patterns_and_non_hash_values
      missing = Julewire::Match.new do
        on(payload: { attempts: Integer }) { :drop }
      end
      missing_nil = Julewire::Match.new do
        on(payload: { missing: nil }) { :drop }
      end
      missing_object = Julewire::Match.new do
        on(payload: { missing: Object }) { :drop }
      end
      partial = Julewire::Match.new do
        on(payload: { attempts: Integer, missing: String }) { :drop }
      end
      empty_nested_hash_on_scalar = Julewire::Match.new do
        on(message: {}) { :drop }
      end
      non_hash = Julewire::Match.new do
        on(message: { length: Integer }) { :drop }
      end

      assert_nil missing.call(draft_for(payload: {}))
      assert_nil missing_nil.call(draft_for(payload: {}))
      assert_nil missing_object.call(draft_for(payload: {}))
      assert_nil partial.call(draft_for(payload: { attempts: 2 }))
      assert_nil empty_nested_hash_on_scalar.call(draft_for(message: "not-hash"))
      assert_nil non_hash.call(draft_for(message: "not-hash"))
    end

    def test_match_rejects_missing_top_level_keys_even_for_nil_patterns
      missing_nil = Julewire::Match.new do
        on(missing: nil) { :drop }
      end
      missing_object = Julewire::Match.new do
        on(missing: Object) { :drop }
      end
      sparse = { event: "match.ready" }

      assert_nil missing_nil.call(sparse)
      assert_nil missing_object.call(sparse)
    end

    private

    def draft_for(input = {})
      Core::Records::Draft.build(input, context: {}, scope: nil)
    end
  end
end
