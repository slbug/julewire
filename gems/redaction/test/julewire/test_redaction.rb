# frozen_string_literal: true

require "test_helper"

module Julewire
  class RedactionTest < Minitest::Test # rubocop:disable Metrics/ClassLength -- Redaction contract coverage.
    cover Julewire::Redaction::Configuration
    cover Julewire::Redaction::Matcher
    cover Julewire::Redaction::Processor
    cover Julewire::Redaction::StringRedactor

    def test_that_it_has_a_version_number
      refute_nil Redaction::VERSION
    end

    def test_configure_requires_block
      error = assert_raises(ArgumentError) { Redaction.configure }

      assert_equal "Julewire::Redaction.configure requires a block", error.message
    end

    def test_config_can_be_assigned
      configuration = Redaction::Configuration.new
      configuration.mask = "[SECRET]"

      Redaction.config = configuration

      assert_same configuration, Redaction.config
    end

    def test_config_can_be_reset
      configuration = Redaction::Configuration.new
      Redaction.config = configuration

      Redaction.reset!

      refute_same configuration, Redaction.config
      assert_equal Redaction::DEFAULT_MASK, Redaction.config.mask
    end

    def test_config_assignment_rejects_wrong_type
      assert_raises(TypeError) { Redaction.config = Object.new }
    end

    def test_processor_satisfies_julewire_processor_contract
      result = assert_julewire_processor_contract(Redaction::Processor.new)

      assert_instance_of Core::Records::Draft, result
    end

    def test_processor_satisfies_julewire_runtime_integration_contract
      output = StringIO.new
      formatter = :to_h.to_proc

      point, summary, health = assert_julewire_runtime_integration_contract(
        configure: lambda do |config|
          config.destinations.use(:default, formatter: formatter, output: output)
          config.processors.use :redaction
        end,
        records: -> { output.string.lines.map { JSON.parse(it) } },
        event_path: %w[event],
        context_path: %w[context],
        carry_path: %w[carry],
        summary_payload_path: %w[payload]
      )

      assert_equal(
        { message: "point", summary_kind: "summary", status: :ok },
        { message: point.fetch("message"), summary_kind: summary.fetch("kind"), status: health.fetch(:status) }
      )
    end

    def test_processor_failure_satisfies_julewire_failure_containment_contract
      filter = lambda do |_key, _value|
        raise "filter failed"
      end
      health, destination_health = assert_julewire_failure_containment_contract(
        configure: lambda do |config|
          config.destinations.use(:default, output: StringIO.new)
          config.processors.use :redaction, [filter]
        end
      )

      assert_equal(
        { phase: :processor, destination_status: :ok },
        { phase: health.dig(:pipeline, :last_failure, :phase), destination_status: destination_health.fetch(:status) }
      )
    end

    def test_redacts_configured_filters_in_nested_record_sections
      record = normalized_record(
        payload: {
          access_token: "secret-token",
          nested: {
            client_secret: "client-secret",
            attempt_count: 2
          },
          list: [
            { api_key: "api-key" },
            "plain"
          ]
        }
      )

      result = apply_redaction(Redaction::Processor.new(string_values: true), record)

      assert_equal(
        {
          access_token: "[FILTERED]",
          nested: { client_secret: "[FILTERED]", attempt_count: 2 },
          list: [{ api_key: "[FILTERED]" }, "plain"]
        },
        result.fetch(:payload)
      )
    end

    def test_does_not_mutate_original_record
      record = normalized_record(payload: { access_token: "secret-token" })

      result = apply_redaction(Redaction::Processor.new(string_values: true), record)

      assert_equal "secret-token", record.fetch(:payload).fetch(:access_token)
      refute_same record.fetch(:payload), result.fetch(:payload)
    end

    def test_processor_preserves_lineage_ancestors
      ancestors = [{ type: "request", id: "request-1" }]
      record = normalized_record(
        execution: {
          type: "job",
          id: "job-1",
          ancestors: ancestors,
          access_token: "secret-token"
        }
      )

      result = apply_redaction(Redaction::Processor.new, record)

      assert_equal ancestors, result.lineage.ancestors
      assert_equal "[FILTERED]", result.dig(:execution, :access_token)
    end

    def test_redacts_string_leaves
      record = normalized_record(
        message: "Authorization: Bearer abc123\nCookie: sid=abc\nX-Api-Key: abc123",
        payload: {
          raw: "access_token=abc123&scope=read",
          json: '{"client_secret":"secret","name":"ok"}'
        }
      )

      result = apply_redaction(Redaction::Processor.new(string_values: true), record)

      assert_equal "Authorization: [FILTERED]\nCookie: [FILTERED]\nX-Api-Key: [FILTERED]", result.fetch(:message)
      assert_equal "access_token=[FILTERED]&scope=read", result.fetch(:payload).fetch(:raw)
      assert_equal '{"client_secret":"[FILTERED]","name":"ok"}', result.fetch(:payload).fetch(:json)
    end

    def test_authorization_header_redaction_can_be_disabled
      record = normalized_record(message: "Authorization: Bearer abc123")

      result = apply_redaction(
        Redaction::Processor.new([], string_values: true, authorization_header: false),
        record
      )

      assert_equal "Authorization: Bearer abc123", result.fetch(:message)
    end

    def test_redacts_error_string_leaves
      record = normalized_record(
        error: {
          class: "RuntimeError",
          message: "access_token=abc123"
        }
      )

      result = apply_redaction(Redaction::Processor.new(string_values: true), record)

      assert_equal "access_token=[FILTERED]", result.dig(:error, :message)
      assert_equal "RuntimeError", result.dig(:error, :class)
    end

    def test_string_redactor_skips_plain_strings
      redactor = Redaction::StringRedactor.new(
        matcher: Redaction::Matcher.new(%i[access_token]),
        mask: "[FILTERED]"
      )
      value = "plain log line"

      assert_same value, redactor.call(value)
    end

    def test_string_redactor_returns_non_strings
      redactor = Redaction::StringRedactor.new(
        matcher: Redaction::Matcher.new(%i[token]),
        mask: "[FILTERED]"
      )

      assert_nil redactor.call(nil)
      assert_equal 123, redactor.call(123)
    end

    def test_string_redactor_can_redact_authorization_without_key_filters
      redactor = Redaction::StringRedactor.new(
        matcher: Redaction::Matcher.new([]),
        mask: "[FILTERED]"
      )

      assert_equal "Authorization: [FILTERED]", redactor.call("Authorization: Bearer abc123")
      assert_equal "token=abc123", redactor.call("token=abc123")
    end

    def test_string_redactor_honors_authorization_header_flag
      redactor = Redaction::StringRedactor.new(
        matcher: Redaction::Matcher.new([]),
        mask: "[FILTERED]",
        authorization_header: false
      )

      assert_equal "Authorization: Bearer abc123", redactor.call("Authorization: Bearer abc123")
    end

    def test_string_redactor_redacts_multiline_headers
      redactor = Redaction::StringRedactor.new(
        matcher: Redaction::Matcher.new(%i[x_api_key]),
        mask: "[FILTERED]",
        authorization_header: false
      )

      assert_equal "Content-Type: text/plain\nX-Api-Key: [FILTERED]", redactor.call(
        "Content-Type: text/plain\nX-Api-Key: abc123"
      )
    end

    def test_matcher_accepts_single_filter_case_insensitively
      matcher = Redaction::Matcher.new(:token)

      assert_filter_match matcher, :token
      assert_filter_match matcher, "TOKEN"
    end

    def test_matcher_rejects_partial_single_filter
      matcher = Redaction::Matcher.new(:token)

      refute_filter_match matcher, :token_count
      refute_filter_match matcher, "account.token"
    end

    def test_matcher_converts_non_string_filters_and_keys
      matcher = Redaction::Matcher.new(123)

      assert_equal [true, false], [matcher.match?(123), matcher.match?(124)]
    end

    def test_matcher_exposes_frozen_blocks
      filter = ->(_key, _value) {}
      matcher = Redaction::Matcher.new([filter])

      assert_equal [filter], matcher.blocks
      assert_predicate matcher.blocks, :frozen?
    end

    def test_matcher_treats_literal_filters_as_literals
      matcher = Redaction::Matcher.new("api+key")

      assert_filter_match matcher, "api+key"
      refute_filter_match matcher, "apikey"
      refute_filter_match matcher, "apiiikey"
    end

    def test_matcher_reports_empty_state
      assert_predicate Redaction::Matcher.new(nil), :empty?
      assert_predicate Redaction::Matcher.new([]), :empty?
      refute_predicate Redaction::Matcher.new(:token), :empty?
    end

    def test_matcher_reports_path_dependency
      refute_predicate Redaction::Matcher.new(:token), :path_dependent?
      assert_predicate Redaction::Matcher.new("user.email"), :path_dependent?
      assert_predicate Redaction::Matcher.new(Redaction.path(/user\.email/)), :path_dependent?
    end

    def test_matcher_matches_path_aware_filters_only_by_path
      matcher = Redaction::Matcher.new("user.email")

      refute_filter_match matcher, :email
      assert matcher.match?(:email, path: "payload.user.email")
      refute matcher.match?(:email, path: "payload.account.email")
    end

    def test_matcher_path_wrapper_keeps_regex_path_aware
      assert_path_wrapper_match(
        Redaction.path(/user\.email/),
        key: :email,
        matching_path: "payload.user.email",
        non_matching_path: "payload.account.email"
      )
    end

    def test_matcher_path_wrapper_for_literal_key_is_path_aware
      assert_path_wrapper_match(
        Redaction.path(:token),
        key: :token,
        matching_path: "payload.account.token",
        non_matching_path: "payload.token_count"
      )
    end

    def test_matcher_string_prefilter_for_literal_filters
      matcher = Redaction::Matcher.new(%i[token password])

      assert matcher.string_key_possible?("token=secret")
      assert matcher.string_key_possible?("PASSWORD=secret")
      refute matcher.string_key_possible?("plain=value")
    end

    def test_matcher_string_prefilter_escapes_literal_filters
      matcher = Redaction::Matcher.new(["api+key"])

      assert matcher.string_key_possible?("api+key=secret")
      refute matcher.string_key_possible?("apikey=secret")
    end

    def test_matcher_string_prefilter_allows_regex_filters
      matcher = Redaction::Matcher.new([/auth_secret/])

      assert matcher.string_key_possible?("plain=value")
    end

    def test_matcher_string_prefilter_allows_mixed_regex_filters
      matcher = Redaction::Matcher.new([:token, /auth_secret/])

      assert matcher.string_key_possible?("plain=value")
    end

    def test_string_redactor_corpus_pins_supported_and_unsupported_shapes
      redactor = Redaction::StringRedactor.new(
        matcher: Redaction::Matcher.new(%i[api_key password token x_api_key]),
        mask: "[FILTERED]"
      )

      cases = {
        "Authorization: Bearer secret" => "Authorization: [FILTERED]",
        "X-Api-Key: secret\nContent-Type: application/json" => "X-Api-Key: [FILTERED]\nContent-Type: application/json",
        "password=secret&name=ok" => "password=[FILTERED]&name=ok",
        "Api_Key=secret&name=ok" => "Api_Key=[FILTERED]&name=ok",
        "?api_key=secret&name=ok" => "?api_key=[FILTERED]&name=ok",
        "TOKEN=secret&name=ok" => "TOKEN=[FILTERED]&name=ok",
        '{"password":"secret","name":"ok"}' => '{"password":"[FILTERED]","name":"ok"}',
        '{"password":"","name":"ok"}' => '{"password":"[FILTERED]","name":"ok"}',
        "{'token':'secret','name':'ok'}" => "{'token':'[FILTERED]','name':'ok'}",
        '{"password":12345,"name":"ok"}' => '{"password":12345,"name":"ok"}'
      }

      cases.each do |input, expected|
        assert_equal expected, redactor.call(input), input
      end
    end

    def test_string_redactor_large_input_preserves_supported_redaction
      redactor = Redaction::StringRedactor.new(
        matcher: Redaction::Matcher.new(%i[token password]),
        mask: "[FILTERED]"
      )
      input = +"prefix "
      input << ("x" * 16_384)
      input << " token=secret "
      input << ("y" * 16_384)

      result = redactor.call(input)

      assert_includes result, "token=[FILTERED]"
      refute_includes result, "token=secret"
      assert_equal input.bytesize - "secret".bytesize + "[FILTERED]".bytesize, result.bytesize
    end

    def test_string_leaf_redaction_is_opt_in
      record = normalized_record(message: "access_token=abc123")

      result = apply_redaction(Redaction::Processor.new, record)

      assert_equal "access_token=abc123", result.fetch(:message)
    end

    def test_empty_filters_without_string_redaction_is_noop
      draft = Core::Records::Draft.from_record(
        normalized_record(payload: { access_token: "secret-token" }),
        freeze_sections: false
      )
      processor = Redaction::Processor.new([], string_values: false)

      assert_same draft, processor.call(draft)
      assert_equal "secret-token", draft.to_record.dig(:payload, :access_token)
    end

    def test_default_key_filters_do_not_match_common_non_secret_fields
      record = normalized_record(
        payload: {
          token_count: 128,
          cache_key: "users/1",
          asphalt: "road"
        }
      )

      result = apply_redaction(Redaction::Processor.new, record)

      assert_equal 128, result.dig(:payload, :token_count)
      assert_equal "users/1", result.dig(:payload, :cache_key)
      assert_equal "road", result.dig(:payload, :asphalt)
    end

    def test_default_key_filters_still_match_exact_secret_fields
      record = normalized_record(payload: { token: "secret-token", secret: "secret-value" })

      result = apply_redaction(Redaction::Processor.new, record)

      assert_equal "[FILTERED]", result.dig(:payload, :token)
      assert_equal "[FILTERED]", result.dig(:payload, :secret)
    end

    def test_filter_profiles_split_secrets_from_pii
      assert_includes Redaction::SECRET_FILTERS, :token
      refute_includes Redaction::SECRET_FILTERS, :email
      assert_equal (Redaction::SECRET_FILTERS + Redaction::PII_FILTERS).uniq, Redaction::DEFAULT_FILTERS
    end

    def test_accepts_rails_style_positional_filters_and_mask
      record = normalized_record(payload: { token: "secret" })

      result = apply_redaction(Redaction::Processor.new([:token], mask: "[SECRET]"), record)

      assert_equal "[SECRET]", result.fetch(:payload).fetch(:token)
    end

    def test_can_match_configured_key_patterns
      record = normalized_record(
        message: "x_auth_secret=abc123",
        payload: { x_auth_secret: "hidden" }
      )

      result = apply_redaction(Redaction::Processor.new([/auth_secret/], string_values: true), record)

      assert_equal "x_auth_secret=[FILTERED]", result.fetch(:message)
      assert_equal "[FILTERED]", result.fetch(:payload).fetch(:x_auth_secret)
    end

    def test_can_match_nested_path_filters
      assert_redacts_credit_card_code("credit_card.code")
    end

    def test_can_match_root_qualified_nested_path_filters
      assert_redacts_credit_card_code("payload.credit_card.code")
    end

    def test_can_match_explicit_regex_path_filters
      record = normalized_record(
        payload: {
          user: { email: "secret@example.test" },
          file: { email: "public@example.test" }
        }
      )

      result = apply_redaction(Redaction::Processor.new([Redaction.path(/user.email/)]), record)

      assert_equal "[FILTERED]", result.fetch(:payload).fetch(:user).fetch(:email)
      assert_equal "public@example.test", result.fetch(:payload).fetch(:file).fetch(:email)
    end

    def test_raw_regex_filters_match_keys_not_paths
      record = normalized_record(
        payload: {
          user: { email: "secret@example.test" },
          "user.email": "literal@example.test"
        }
      )

      result = apply_redaction(Redaction::Processor.new([/user\.email/]), record)

      assert_equal "secret@example.test", result.fetch(:payload).fetch(:user).fetch(:email)
      assert_equal "[FILTERED]", result.fetch(:payload).fetch(:"user.email")
    end

    def test_top_level_message_key_can_be_redacted
      record = normalized_record(message: "secret message")

      result = apply_redaction(Redaction::Processor.new([:message]), record)

      assert_equal "[FILTERED]", result.fetch(:message)
    end

    def test_redaction_preserved_scalar_fields_track_field_bags
      record = normalized_record(redaction_scalar_probe)

      result = apply_redaction(Redaction::Processor.new(Core::Fields::Bags.record_scalar_keys), record)

      (Core::Fields::Bags.record_scalar_keys - %i[message]).each do |key|
        assert_equal record.fetch(key), result.fetch(key), "expected #{key} to stay structural"
      end
      assert_equal "[FILTERED]", result.fetch(:message)
    end

    def test_redaction_preserves_top_level_routing_fields
      record = normalized_record(event: "account.updated", logger: "App", source: "worker")

      result = apply_redaction(Redaction::Processor.new(%i[event logger source]), record)

      assert_equal "account.updated", result.fetch(:event)
      assert_equal "App", result.fetch(:logger)
      assert_equal "worker", result.fetch(:source)
    end

    def test_redaction_preserves_record_structural_fields
      record = normalized_record(payload: { visible: "ok" })

      result = apply_redaction(Redaction::Processor.new(%i[payload severity error]), record)

      assert_equal({ visible: "ok" }, result.fetch(:payload))
      assert_equal :info, result.fetch(:severity)
      assert_nil result.fetch(:error)
    end

    def test_supports_rails_style_proc_filters
      record = normalized_record(payload: { prefix: "signed", nested: { signature: "abc" } })

      result = apply_redaction(Redaction::Processor.new([signature_filter], string_values: false), record)

      assert_equal "signed-abc", result.dig(:payload, :nested, :signature)
    end

    def test_supports_two_argument_proc_filters
      filter = lambda do |key, value|
        value.replace("#{key}:#{value}") if key == "signature"
      end
      record = normalized_record(payload: { signature: "abc" })

      result = apply_redaction(Redaction::Processor.new([filter], string_values: false), record)

      assert_equal "signature:abc", result.dig(:payload, :signature)
    end

    def test_proc_filters_do_not_mutate_original_string_values
      record = normalized_record(payload: { prefix: "signed", signature: "abc" })

      result = apply_redaction(Redaction::Processor.new([signature_filter], string_values: false), record)

      assert_equal "abc", record.dig(:payload, :signature)
      assert_equal "signed-abc", result.dig(:payload, :signature)
    end

    def test_proc_filters_leave_non_string_scalars_intact
      seen = []
      filter = lambda do |_key, value|
        seen << value
      end
      record = normalized_record(payload: { attempts: 2 })

      result = apply_redaction(Redaction::Processor.new([filter], string_values: false), record)

      assert_includes seen, 2
      assert_equal 2, result.dig(:payload, :attempts)
    end

    def test_proc_filters_receive_root_original_inside_arrays
      record = normalized_record(payload: { prefix: "signed", list: [{ signature: "abc" }] })

      result = apply_redaction(Redaction::Processor.new([signature_filter], string_values: false), record)

      assert_equal "signed-abc", result.dig(:payload, :list, 0, :signature)
    end

    def test_redacts_matching_keys_across_all_record_sections
      record = normalized_record(
        execution: { type: "request", access_token: "execution-token" },
        attributes: { client_secret: "attribute-secret" },
        carry: { access_token: "carry-token" },
        error: { class: "RuntimeError", access_token: "error-token" },
        labels: { access_token: "label-token" },
        neutral: { access_token: "neutral-token" },
        payload: { access_token: "payload-token" }
      )

      result = apply_redaction(Redaction::Processor.new, record)

      redacted_section_paths.each_value do |path|
        assert_equal "[FILTERED]", result.dig(*path)
      end
    end

    def test_uses_redaction_configuration_by_default
      Redaction.configure do |config|
        config.filters = %i[tenant_secret]
        config.mask = "[SECRET]"
        config.string_values = false
      end

      record = normalized_record(
        message: "tenant_secret=visible",
        labels: { tenant_secret: "label-secret" },
        payload: { tenant_secret: "payload-secret", access_token: "left-alone" }
      )

      result = apply_redaction(Redaction::Processor.new, record)

      assert_equal configured_redaction_result, redaction_result_summary(result)
    end

    def test_uses_string_redaction_configuration_by_default
      Redaction.configure do |config|
        config.filters = %i[tenant_secret]
        config.string_values = true
      end

      record = normalized_record(message: "tenant_secret=visible")

      result = apply_redaction(Redaction::Processor.new, record)

      assert_equal "tenant_secret=[FILTERED]", result.fetch(:message)
    end

    def test_mask_is_stringified
      record = normalized_record(payload: { token: "secret" })

      result = apply_redaction(Redaction::Processor.new([:token], mask: :MASKED), record)

      assert_equal "MASKED", result.dig(:payload, :token)
    end

    def test_integrates_with_julewire_pipeline
      output = StringIO.new

      Julewire.configure do |config|
        config.destinations.use(:default, output: output)
        config.processors.use :redaction
      end

      Julewire.emit(
        message: "created access_token=abc123",
        payload: { access_token: "secret-token", id: 123 }
      )

      parsed = JSON.parse(output.string)

      assert_equal "created access_token=abc123", parsed.fetch("message")
      assert_equal "[FILTERED]", parsed.fetch("payload").fetch("access_token")
      assert_equal 123, parsed.fetch("payload").fetch("id")
    end

    def test_rejects_non_normalized_processor_input
      error = assert_raises(TypeError) do
        Redaction::Processor.new.call("not a record")
      end

      assert_match(/Julewire::RecordDraft/, error.message)
    end

    def test_rejects_non_positive_max_depth
      assert_raises(ArgumentError) { Redaction::Processor.new(max_depth: 0) }
    end

    def test_allows_zero_collection_and_string_limits
      processor = Redaction::Processor.new(
        [:token],
        max_array_items: 0,
        max_hash_keys: 0,
        max_string_bytes: 0
      )
      record = normalized_record(payload: { token: "secret" })

      result = apply_redaction(processor, record)

      assert result.fetch(:payload).key?(:_julewire_truncation)
    end

    private

    def assert_filter_match(matcher, key)
      matched = matcher.match?(key)

      assert matched, "expected #{key.inspect} to match filter"
    end

    def refute_filter_match(matcher, key)
      matched = matcher.match?(key)

      refute matched, "expected #{key.inspect} not to match filter"
    end

    def assert_path_wrapper_match(filter, key:, matching_path:, non_matching_path:)
      matcher = Redaction::Matcher.new(filter)

      refute_filter_match matcher, key
      assert matcher.match?(key, path: matching_path)
      refute matcher.match?(key, path: non_matching_path)
    end

    def normalized_record(input = {})
      Core::Records::Draft.build(input, context: {}, scope: nil).to_record
    end

    def redaction_scalar_probe
      {
        timestamp: Time.utc(2026, 1, 1),
        severity: :warn,
        kind: :point,
        event: "scalar.probe",
        message: "secret message",
        logger: "App",
        source: "worker"
      }
    end

    def apply_redaction(processor, record)
      processor.call(Core::Records::Draft.from_record(record)).to_record
    end

    def assert_redacts_credit_card_code(filter)
      record = normalized_record(
        payload: {
          credit_card: { code: "123" },
          file: { code: "abc" }
        }
      )

      result = apply_redaction(Redaction::Processor.new([filter]), record)

      assert_equal "[FILTERED]", result.fetch(:payload).fetch(:credit_card).fetch(:code)
      assert_equal "abc", result.fetch(:payload).fetch(:file).fetch(:code)
    end

    def signature_filter
      lambda do |key, value, original|
        value.replace("#{original.dig(:payload, :prefix)}-#{value}") if key == "signature"
      end
    end

    def configured_redaction_result
      {
        message: "tenant_secret=visible",
        label_secret: "[SECRET]",
        payload_secret: "[SECRET]",
        access_token: "left-alone"
      }
    end

    def redaction_result_summary(result)
      {
        message: result.fetch(:message),
        label_secret: result.fetch(:labels).fetch(:tenant_secret),
        payload_secret: result.fetch(:payload).fetch(:tenant_secret),
        access_token: result.fetch(:payload).fetch(:access_token)
      }
    end

    def redacted_section_paths
      {
        execution: %i[execution access_token],
        attributes: %i[attributes client_secret],
        carry: %i[carry access_token],
        error: %i[error access_token],
        neutral: %i[neutral access_token],
        payload: %i[payload access_token],
        label: %i[labels access_token]
      }
    end
  end
end
