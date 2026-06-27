# frozen_string_literal: true

require "test_helper"

module Julewire
  class RedactionProcessorTestCase < Minitest::Test; end

  class RedactionProcessorTest < RedactionProcessorTestCase
    cover "Julewire::Redaction::Matcher#deep_filter?"
    cover "Julewire::Redaction::Matcher#empty?"
    cover "Julewire::Redaction::Matcher#string_scan_pattern"
    cover "Julewire::Redaction::Processor#apply_block_filters"
    cover "Julewire::Redaction::Processor#call"
    cover "Julewire::Redaction::Processor#duplicate_filter_value"
    cover "Julewire::Redaction::Processor#initialize"
    cover "Julewire::Redaction::Processor#redact_item"
    cover "Julewire::Redaction::Processor#redact_record"
    cover "Julewire::Redaction::Processor#redact_scalar"
    cover "Julewire::Redaction::Processor#redacted_key?"
    cover "Julewire::Redaction::Processor#validate_draft!"

    def test_processor_runs_in_pipeline_for_execution_point_and_summary
      output = StringIO.new
      formatter = :to_h.to_proc
      traceparent = "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01"

      Julewire.configure do |config|
        config.destinations.use(:default, formatter: formatter, output: output)
        config.processors.use :redaction
      end
      Julewire.with_execution(type: :contract, id: "contract-1", summary_event: "contract.completed") do
        Julewire.context.add(request_id: "request-1")
        Julewire.carry.add(http: { request_headers: { traceparent: traceparent } })
        Julewire.summary.add(total: 2)
        Julewire.emit(event: "contract.point", source: "contract", message: "point", payload: { value: 1 })
      end
      Julewire.flush

      records = output.string.lines.map { JSON.parse(it) }
      point = records.find { it.fetch("event") == "contract.point" }
      summary = records.find { it.fetch("event") == "contract.completed" }

      assert_equal(
        { message: "point", summary_kind: "summary", status: :ok },
        {
          message: point.fetch("message"),
          summary_kind: summary.fetch("kind"),
          status: Julewire.health.fetch(:status)
        }
      )
      assert_equal(
        { request_id: "request-1", total: 2, traceparent: traceparent },
        {
          request_id: point.dig("context", "request_id"),
          total: summary.dig("payload", "total"),
          traceparent: point.dig("carry", "http", "request_headers", "traceparent")
        }
      )
    end

    def test_processor_failure_is_contained_and_reported
      filter = lambda do |_key, _value|
        raise "filter failed"
      end
      Julewire.configure do |config|
        config.destinations.use(:default, output: StringIO.new)
        config.processors.use :redaction, [filter]
      end

      assert_nil Julewire.emit(event: "redaction.failure", source: "test")

      health = Julewire.health
      destination_health = health.dig(:pipeline, :destinations, :default)

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
  end

  class RedactionStringRedactorTest < Minitest::Test
    cover "Julewire::Redaction::Matcher#string_scan_pattern"
    cover Julewire::Redaction::StringRedactor

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

    def test_string_redactor_handles_string_subclasses
      redactor = Redaction::StringRedactor.new(
        matcher: Redaction::Matcher.new(%i[token]),
        mask: "[FILTERED]"
      )
      value = Class.new(String).new("token=secret")

      assert_equal "token=[FILTERED]", redactor.call(value)
    end

    def test_string_redactor_can_redact_authorization_without_key_filters
      redactor = Redaction::StringRedactor.new(
        matcher: Redaction::Matcher.new([]),
        mask: "[FILTERED]"
      )

      assert_equal "Authorization: [FILTERED]", redactor.call("Authorization: Bearer abc123")
      assert_equal "token=abc123", redactor.call("token=abc123")
    end

    def test_string_redactor_authorization_only_skips_pair_scans
      value = authorization_scan_probe

      assert_equal "Authorization: [FILTERED]", string_redactor.call(value)
    end

    def test_string_redactor_stringifies_mask
      redactor = Redaction::StringRedactor.new(
        matcher: Redaction::Matcher.new(%i[token]),
        mask: :MASKED
      )

      assert_equal "token=MASKED", redactor.call("token=secret")
    end

    def test_string_redactor_coerces_mask_once_at_initialization
      calls = 0
      mask = Object.new
      mask.define_singleton_method(:to_s) do
        calls += 1
        "MASK-#{calls}"
      end
      redactor = Redaction::StringRedactor.new(
        matcher: Redaction::Matcher.new(%i[token]),
        mask: mask
      )

      assert_equal "token=MASK-1", redactor.call("token=secret")
      assert_equal "token=MASK-1", redactor.call("token=secret")
      assert_equal 1, calls
    end

    def test_string_redactor_honors_authorization_header_flag
      redactor = string_redactor(authorization_header: false)

      assert_equal "Authorization: Bearer abc123", redactor.call("Authorization: Bearer abc123")
    end

    def test_string_redactor_disabled_authorization_header_stays_disabled_with_filters
      redactor = string_redactor(filters: %i[token], authorization_header: false)

      assert_equal "Authorization: Bearer abc123", redactor.call("Authorization: Bearer abc123")
    end

    def test_string_redactor_disabled_authorization_without_filters_is_identity
      value = "Authorization: Bearer abc123"

      assert_same value, string_redactor(authorization_header: false).call(value)
    end

    def test_string_redactor_without_filters_keeps_form_strings_by_identity
      value = "token=secret"

      assert_same value, string_redactor(authorization_header: false).call(value)
    end

    def test_string_redactor_redacts_json_pairs_without_authorization_header_scan
      redactor = string_redactor(filters: [:token], authorization_header: false)

      assert_equal '{"token":"[FILTERED]"}', redactor.call('{"token":"secret"}')
      assert_equal "{'token':'[FILTERED]'}", redactor.call("{'token':'secret'}")
      assert_equal "not-json token: secret", redactor.call("not-json token: secret")
    end

    def test_string_redactor_redacts_form_pairs_without_header_scan
      redactor = string_redactor(filters: [:token], authorization_header: false)

      assert_equal "token=[FILTERED]", redactor.call("token=secret")
    end

    def test_string_redactor_keeps_pair_strings_without_matching_literal_key
      redactor = string_redactor(filters: [:token], authorization_header: false)
      value = "password=secret"

      assert_equal value, redactor.call(value)
    end

    def test_string_redactor_skips_form_scan_without_equals
      value = scan_probe("token secret")

      assert_same value, string_redactor(filters: [:token], authorization_header: false).call(value)
    end

    def test_string_redactor_skips_json_scan_without_required_syntax
      {
        quotes: "not-json token: secret",
        colon: 'token="secret"'
      }.each do |missing, input|
        value = scan_probe(input, allowed_scans: 1)

        assert_equal value,
                     string_redactor(filters: [:token], authorization_header: false).call(value),
                     "JSON scan should stop with missing #{missing} syntax"
      end
    end

    def test_string_redactor_redacts_multiline_headers
      redactor = string_redactor(filters: %i[x_api_key], authorization_header: false)

      assert_equal "Content-Type: text/plain\nX-Api-Key: [FILTERED]", redactor.call(
        "Content-Type: text/plain\nX-Api-Key: abc123"
      )
    end

    def test_string_redactor_redacts_empty_header_values
      redactor = Redaction::StringRedactor.new(
        matcher: Redaction::Matcher.new(["x-api-key"]),
        mask: "[FILTERED]"
      )

      assert_equal "X-Api-Key:[FILTERED]", redactor.call("X-Api-Key:")
    end

    def test_string_redactor_header_edges
      redactor = Redaction::StringRedactor.new(
        matcher: Redaction::Matcher.new(["x-api-key"]),
        mask: "[FILTERED]"
      )

      assert_equal "authorization:[FILTERED]", redactor.call("authorization:Bearer abc123")
      assert_equal "Authorization: [FILTERED]", redactor.call('Authorization: ""')
      assert_equal "Content-Type: text/plain\rX-Api-Key: [FILTERED]", redactor.call(
        "Content-Type: text/plain\rX-Api-Key: abc123"
      )
    end

    private

    def string_redactor(filters: [], authorization_header: true)
      Redaction::StringRedactor.new(
        matcher: Redaction::Matcher.new(filters),
        mask: "[FILTERED]",
        authorization_header:
      )
    end

    def scan_probe(value, allowed_scans: 0)
      scans = 0
      Class.new(String) do
        define_method(:gsub!) do |pattern, &block|
          scans += 1
          raise "unexpected string redaction scan" if scans > allowed_scans

          super(pattern, &block)
        end
      end.new(value)
    end

    def authorization_scan_probe
      scans = 0
      Class.new(String) do
        define_method(:gsub!) do |*|
          scans += 1
          raise "pair scans should be skipped" if scans > 1

          replace("Authorization: [FILTERED]")
        end
      end.new('Authorization: "Bearer abc123"')
    end
  end

  class RedactionMatcherTest < Minitest::Test
    cover "Julewire::Redaction.path"
    cover "Julewire::Redaction::Matcher#deep_filter?"
    cover "Julewire::Redaction::Matcher#empty?"
    cover "Julewire::Redaction::Matcher#string_scan_pattern"
    cover Julewire::Redaction::Matcher

    def test_matcher_accepts_single_filter_case_insensitively
      filter_matcher = Redaction::Matcher.new(:token)

      assert_equal [true, true], [filter_matcher.match?(:token), filter_matcher.match?("TOKEN")]
    end

    def test_matcher_rejects_partial_single_filter
      filter_matcher = Redaction::Matcher.new(:token)

      assert_equal [false, false], [filter_matcher.match?(:token_count), filter_matcher.match?("account.token")]
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
      filter_matcher = Redaction::Matcher.new("api+key")

      assert_equal(
        [true, false, false],
        %w[api+key apikey apiiikey].map { filter_matcher.match?(it) }
      )
    end

    def test_matcher_reports_empty_state
      assert_equal(
        [true, true, false, false],
        [nil, [], :token, "user.email"].map { Redaction::Matcher.new(it).empty? }
      )
    end

    def test_matcher_reports_path_dependent_state
      refute_predicate Redaction::Matcher.new(:token), :path_dependent?
      assert_predicate Redaction::Matcher.new("user.email"), :path_dependent?
      assert_predicate Redaction::Matcher.new(Redaction.path(:token)), :path_dependent?
    end

    def test_matcher_string_key_pre_scan_for_literal_filters
      matcher = Redaction::Matcher.new(%i[token])

      assert_true matcher.string_key_possible?("token=secret")
      assert_false matcher.string_key_possible?("password=secret")
    end

    def test_matcher_string_key_pre_scan_allows_regex_and_empty_filters
      assert_true Redaction::Matcher.new([/token/]).string_key_possible?("password=secret")
      assert_true Redaction::Matcher.new([:password, /token/]).string_key_possible?("account=secret")
      assert_true Redaction::Matcher.new([]).string_key_possible?("anything")
    end

    def test_matcher_escapes_literal_string_scan_filters
      matcher = Redaction::Matcher.new("user+email")

      assert_true matcher.string_key_possible?("user+email=secret")
      assert_false matcher.string_key_possible?("user-email=secret")
    end

    def test_matcher_matches_path_aware_filters_only_by_path
      filter_matcher = Redaction::Matcher.new("user.email")

      assert_equal(
        [false, true, false],
        [
          filter_matcher.match?(:email),
          filter_matcher.match?(:email, path: "payload.user.email"),
          filter_matcher.match?(:email, path: "payload.account.email")
        ]
      )
    end

    def test_matcher_path_wrapper_keeps_literal_and_regex_filters_path_aware
      cases = [
        [Redaction.path(/user\.email/), :email, "payload.user.email", "payload.account.email"],
        [Redaction.path(:token), :token, "payload.account.token", "payload.token_count"]
      ]

      cases.each do |filter, key, matching_path, non_matching_path|
        filter_matcher = Redaction::Matcher.new(filter)

        assert_equal(
          [false, true, false],
          [
            filter_matcher.match?(key),
            filter_matcher.match?(key, path: matching_path),
            filter_matcher.match?(key, path: non_matching_path)
          ]
        )
      end
    end

    def test_matcher_keeps_bare_regexes_key_scoped_even_when_the_pattern_contains_a_dot
      filter_matcher = Redaction::Matcher.new(/user\.email/)

      assert_equal(
        [true, false],
        [
          filter_matcher.match?("user.email"),
          filter_matcher.match?(:email, path: "payload.user.email")
        ]
      )
    end
  end

  class RedactionProcessorPathTest < RedactionProcessorTestCase
    cover "Julewire::Redaction::Processor#redact_item"
    cover "Julewire::Redaction::Processor#redact_record"
    cover "Julewire::Redaction::Processor#redacted_key?"

    def test_processor_matches_anchored_path_regexes_against_section_relative_paths
      record = normalized_record(payload: { user: { email: "secret@example.test", id: 1 } })

      result = apply_redaction(Redaction::Processor.new([Redaction.path(/\Auser\.email\z/)]), record)

      assert_equal "[FILTERED]", result.dig(:payload, :user, :email)
      assert_equal 1, result.dig(:payload, :user, :id)
    end

    def test_processor_matches_path_filters_against_top_level_scalar_paths
      record = normalized_record(message: "secret", payload: { visible: "ok" })

      result = apply_redaction(Redaction::Processor.new([Redaction.path(/\Amessage\z/)]), record)

      assert_equal "[FILTERED]", result.fetch(:message)
      assert_equal "ok", result.dig(:payload, :visible)
    end
  end

  class RedactionStringRedactorCorpusTest < Minitest::Test
    cover "Julewire::Redaction::Matcher#string_scan_pattern"
    cover Julewire::Redaction::StringRedactor

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
  end

  class RedactionProcessorConfigurationTest < RedactionProcessorTestCase
    cover "Julewire::Redaction::Processor#apply_block_filters"
    cover "Julewire::Redaction::Processor#call"
    cover "Julewire::Redaction::Processor#duplicate_filter_value"
    cover "Julewire::Redaction::Processor#initialize"
    cover "Julewire::Redaction::Processor#redact_item"
    cover "Julewire::Redaction::Processor#redact_record"
    cover "Julewire::Redaction::Processor#redact_scalar"
    cover "Julewire::Redaction::Processor#redacted_key?"
    def test_string_leaf_redaction_is_opt_in
      record = normalized_record(message: "access_token=abc123")

      result = apply_redaction(Redaction::Processor.new, record)

      assert_equal "access_token=abc123", result.fetch(:message)
    end

    def test_empty_filters_without_string_redaction_is_noop
      draft = Core::Records::Draft.from_record(
        normalized_record(payload: { access_token: "secret-token" })
      )
      record = draft.to_record
      processor = Redaction::Processor.new([], string_values: false)

      assert_same draft, processor.call(draft)
      assert_same record, draft.to_record
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

    def test_can_match_nested_and_root_qualified_path_filters
      ["credit_card.code", "payload.credit_card.code"].each do |filter|
        record = normalized_record(payload: { credit_card: { code: "123" }, file: { code: "abc" } })

        result = apply_redaction(Redaction::Processor.new([filter]), record)

        assert_equal "[FILTERED]", result.dig(:payload, :credit_card, :code)
        assert_equal "abc", result.dig(:payload, :file, :code)
      end
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

    def test_proc_filters_receive_mutable_key_copies
      record = normalized_record(payload: { signature: "abc" })

      result = apply_redaction(Redaction::Processor.new([mutable_signature_filter], string_values: false), record)

      assert_equal "abc", record.dig(:payload, :signature)
      assert_equal({ signature: "filtered" }, result.fetch(:payload))
    end

    def test_proc_filters_do_not_mutate_original_string_subclass_values
      value = Class.new(String).new("abc")
      filter = lambda do |key, filtered_value|
        filtered_value.replace("changed") if key == "signature"
      end
      record = normalized_record(payload: { signature: value })

      result = apply_redaction(Redaction::Processor.new([filter], string_values: false), record)

      assert_equal "abc", record.dig(:payload, :signature)
      assert_equal "changed", result.dig(:payload, :signature)
    end
  end

  class RedactionStringRedactorFastPathTest < Minitest::Test
    cover "Julewire::Redaction::Matcher#string_scan_pattern"
    cover Julewire::Redaction::StringRedactor

    def test_string_redactor_skips_pair_scans_when_no_filter_key_can_match
      value_class = Class.new(String) do
        def gsub!(*)
          raise "pair scans should be skipped"
        end
      end
      value = value_class.new("name=value&age=1")

      redactor = Redaction::StringRedactor.new(
        matcher: Redaction::Matcher.new([:token]),
        mask: "[FILTERED]"
      )

      assert_equal value, redactor.call(value)
    end
  end

  class RedactionProcessorBehaviorTest < RedactionProcessorTestCase
    cover "Julewire::Redaction::Processor#apply_block_filters"
    cover "Julewire::Redaction::Processor#call"
    cover "Julewire::Redaction::Processor#duplicate_filter_value"
    cover "Julewire::Redaction::Processor#initialize"
    cover "Julewire::Redaction::Processor#redact_item"
    cover "Julewire::Redaction::Processor#redact_record"
    cover "Julewire::Redaction::Processor#redact_scalar"
    cover "Julewire::Redaction::Processor#redacted_key?"
    cover "Julewire::Redaction::Processor#validate_draft!"
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

    def test_proc_filters_receive_non_string_scalars_by_identity
      scalar = Object.new
      seen = []
      filter = lambda do |key, value|
        seen << value if key == "opaque"
      end
      record = normalized_record(payload: { opaque: scalar })

      apply_redaction(Redaction::Processor.new([filter], string_values: false), record)

      assert_same scalar, seen.fetch(0)
    end

    def test_proc_filters_do_not_receive_container_values
      seen = []
      filter = lambda do |key, value|
        seen << key if value.is_a?(Hash) || value.is_a?(Array)
      end
      record = normalized_record(payload: { list: [{ token: "secret" }], nested: { token: "secret" } })

      apply_redaction(Redaction::Processor.new([filter], string_values: false), record)

      assert_empty seen
    end

    def test_proc_filters_do_not_receive_container_subclass_values
      seen = []
      filter = lambda do |key, value|
        seen << key if value.is_a?(Hash) || value.is_a?(Array)
      end
      hash = Class.new(Hash).new.merge!(token: "secret")
      array = Class.new(Array).new([{ token: "secret" }])
      record = normalized_record(payload: { hash: hash, array: array })

      apply_redaction(Redaction::Processor.new([filter], string_values: false), record)

      assert_empty seen
    end

    def test_path_filters_redact_keyless_array_children_through_prefixed_paths
      record = normalized_record(payload: { secrets: %w[one two] })

      result = apply_redaction(Redaction::Processor.new([Redaction.path(/\Apayload\.secrets\z/)]), record)

      assert_equal "[FILTERED]", result.dig(:payload, :secrets)
    end

    def test_keyless_array_children_do_not_match_empty_literal_key_filters
      record = normalized_record(payload: { values: ["secret"] })

      result = apply_redaction(Redaction::Processor.new([""]), record)

      assert_equal ["secret"], result.dig(:payload, :values)
    end

    def test_processor_preserves_plain_strings_when_no_block_filter_applies
      message = +"plain"
      record = normalized_record(message: message)
      normalized_message = record.fetch(:message)

      result = apply_redaction(
        Redaction::Processor.new([], string_values: true, authorization_header: false),
        record
      )

      assert_same normalized_message, result.fetch(:message)
    end

    def test_proc_filters_skip_unkeyed_array_scalars
      empty_key_values = []
      filter = lambda do |key, value|
        empty_key_values << value if key.empty?
      end
      record = normalized_record(payload: { list: ["secret"] })

      result = apply_redaction(Redaction::Processor.new([filter], string_values: false), record)

      assert_empty empty_key_values
      assert_equal ["secret"], result.dig(:payload, :list)
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

    def test_uses_authorization_header_configuration_by_default
      Redaction.configure do |config|
        config.filters = []
        config.string_values = true
        config.authorization_header = false
      end
      record = normalized_record(message: "Authorization: Bearer abc123")

      result = apply_redaction(Redaction::Processor.new, record)

      assert_equal "Authorization: Bearer abc123", result.fetch(:message)
    end

    def test_processor_redacts_authorization_header_by_default
      record = normalized_record(message: "Authorization: Bearer abc123")

      result = apply_redaction(Redaction::Processor.new([], string_values: true), record)

      assert_equal "Authorization: [FILTERED]", result.fetch(:message)
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

    def test_processor_validates_against_public_record_draft_constant
      Julewire::Redaction.const_set(:RecordDraft, Class.new)
      fake_draft = Julewire::Redaction::RecordDraft.new

      error = assert_raises(TypeError) do
        Redaction::Processor.new([], string_values: false).call(fake_draft)
      end

      assert_match(/Julewire::RecordDraft/, error.message)
    ensure
      if Julewire::Redaction.const_defined?(:RecordDraft, false)
        Julewire::Redaction.__send__(:remove_const, :RecordDraft)
      end
    end

    def test_rejects_non_positive_max_depth
      error = assert_raises(ArgumentError) { Redaction::Processor.new(max_depth: 0) }

      assert_equal "max_depth must be a positive Integer", error.message
    end

    def test_rejects_invalid_limit_names
      invalid_limits = {
        max_array_items: "max_array_items must be a non-negative Integer",
        max_hash_keys: "max_hash_keys must be a non-negative Integer",
        max_string_bytes: "max_string_bytes must be a non-negative Integer"
      }

      invalid_limits.each do |name, message|
        error = assert_raises(ArgumentError) { Redaction::Processor.new(**{ name => -1 }) }

        assert_equal message, error.message
      end
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

      assert_true result.fetch(:payload).key?(:_julewire_truncation)
    end
  end

  module RedactionProcessorFixtures
    private

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

    def signature_filter
      lambda do |key, value, original|
        value.replace("#{original.dig(:payload, :prefix)}-#{value}") if key == "signature"
      end
    end

    def mutable_signature_filter
      lambda do |key, value|
        next unless key == "signature"

        key.replace("changed")
        value.replace("filtered")
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

  RedactionProcessorTestCase.include(RedactionProcessorFixtures)
end
