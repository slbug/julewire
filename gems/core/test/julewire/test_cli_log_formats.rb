# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module Julewire
  class TestCLILogFormats < Minitest::Test
    cover Julewire::Core::CLI::LogFormats
    cover "Julewire::Core::CLI::LogFormats.auto_decode_entry"

    def test_decode_defaults_to_auto_format
      payload = core_payload(message: "auto", event: "tail.auto")

      decoded = Core::CLI::LogFormats.decode(payload)

      assert_equal "tail.auto", decoded.fetch(:event)
      assert_equal "auto", decoded.fetch(:message)
    end

    def test_decode_accepts_hash_subclasses
      payload = Class.new(Hash).new.merge!(core_payload(event: "tail.subclass"))

      decoded = Core::CLI::LogFormats.decode(payload)

      assert_equal "tail.subclass", decoded.fetch(:event)
    end

    def test_core_log_decoder_reads_sections_from_bag_taxonomy
      payload = {
        "timestamp" => "2026-06-19T10:00:00Z",
        "severity" => "info",
        "kind" => "point",
        "event" => "tail.event"
      }
      Core::Fields::Bags.record_hash_sections.each do |section|
        payload[section.to_s] = { "value" => section.to_s }
      end

      decoded = Core::CLI::LogFormats.decode(payload, format: :core)

      Core::Fields::Bags.record_hash_sections.each do |section|
        assert_equal({ value: section.to_s }, decoded.fetch(section))
      end
    end

    def test_core_log_decoder_match_requires_timestamp_severity_and_core_kind
      decoder = Core::CLI::LogFormats::CoreJsonDecoder
      payload = core_payload

      assert_true decoder_matches?(decoder, payload)
      assert_true decoder_matches?(decoder, payload.merge("kind" => :summary))
      assert_false decoder_matches?(decoder, payload.except("timestamp"))
      assert_false decoder_matches?(decoder, payload.except("severity"))
      assert_false decoder_matches?(decoder, payload.except("kind"))
      assert_false decoder_matches?(decoder, payload.merge("kind" => "custom"))
    end

    def test_core_log_decoder_maps_scalar_fields
      payload = core_payload(
        message: "decoded message",
        event: "tail.decoded"
      ).merge(
        "severity" => "warn",
        "kind" => "summary",
        "logger" => "julewire",
        "source" => "app/jobs/report.rb:12"
      )

      decoded = Core::CLI::LogFormats.decode(payload, format: :core)

      assert_equal "2026-06-19T10:00:00Z", decoded.fetch(:timestamp)
      assert_equal :warn, decoded.fetch(:severity)
      assert_equal :summary, decoded.fetch(:kind)
      assert_equal "tail.decoded", decoded.fetch(:event)
      assert_equal "decoded message", decoded.fetch(:message)
      assert_equal "julewire", decoded.fetch(:logger)
      assert_equal "app/jobs/report.rb:12", decoded.fetch(:source)
    end

    def test_core_log_decoder_decodes_error_section
      decoded = Core::CLI::LogFormats.decode(
        core_payload.merge("error" => { "class" => "RuntimeError", "message" => "boom" }),
        format: :core
      )

      assert_equal({ class: "RuntimeError", message: "boom" }, decoded.fetch(:error))
    end

    def test_core_log_decoder_leaves_optional_scalar_fields_nil
      decoded = Core::CLI::LogFormats.decode(
        {
          "timestamp" => "2026-06-19T10:00:00Z",
          "severity" => "info",
          "kind" => "point"
        },
        format: :core
      )

      assert_nil decoded.fetch(:event)
      assert_nil decoded.fetch(:message)
      assert_nil decoded.fetch(:logger)
      assert_nil decoded.fetch(:source)
    end

    def test_core_log_decoder_direct_call_requires_core_shape
      payload = core_payload

      %w[timestamp severity kind].each do |key|
        error = assert_raises(KeyError) do
          Core::CLI::LogFormats::CoreJsonDecoder.call(payload.reject { |candidate, _value| candidate == key })
        end

        assert_equal "key not found: #{key.inspect}", error.message
      end
    end

    def test_record_decoder_kind_normalizes_wire_values
      pointish = Object.new
      def pointish.to_s = "point"
      def pointish.to_sym = :wrong

      kindish = Object.new
      def kindish.to_s = "summary"
      def kindish.to_sym = :wrong

      custom = Object.new
      def custom.to_s = "custom"
      def custom.to_sym = :custom

      decoder = Core::CLI::LogFormats::RecordDecoder

      assert_equal :point, decoder.kind("point")
      assert_equal :point, decoder.kind(pointish)
      assert_equal :summary, decoder.kind(:summary)
      assert_equal :summary, decoder.kind(kindish)
      assert_equal :custom, decoder.kind(custom)
    end

    def test_record_decoder_sections_accept_hash_subclasses_and_block_remaps
      decoder = Core::CLI::LogFormats::RecordDecoder
      hash_subclass = Class.new(Hash).new.merge!("value" => "subclass")
      source = { "payload" => hash_subclass }
      yielded = []

      assert_nil decoder.error(nil)
      assert_equal({ value: "subclass" }, decoder.section(hash_subclass))
      assert_equal({}, decoder.section("not-a-hash"))
      assert_equal({ payload: { value: "subclass" } }, decoder.sections(source, sections: [:payload]))

      remapped = decoder.sections(source, sections: [:attributes]) do |name, passed_source|
        yielded << [name, passed_source]
        { "remapped" => name.to_s }
      end

      assert_equal({ attributes: { remapped: "attributes" } }, remapped)
      assert_equal [[:attributes, source]], yielded
    end

    def test_record_from_json_line_defaults_to_auto_format
      record = Core::CLI::LogFormats.record_from_json_line(JSON.generate(core_payload), line_number: 7)

      assert_equal "tail.event", record.fetch(:event)
    end

    def test_record_from_json_line_reports_json_parser_message
      error = assert_raises(ArgumentError) do
        Core::CLI::LogFormats.record_from_json_line("{", line_number: 9)
      end

      assert_match(/\Aline 9: invalid JSON: /, error.message)
      assert_match(/unexpected|expected/i, error.message)
    end

    def test_record_from_json_line_reports_decode_message
      error = assert_raises(ArgumentError) do
        Core::CLI::LogFormats.record_from_json_line(JSON.generate([]), line_number: 11)
      end

      assert_equal "line 11: log entry must be a JSON object", error.message
    end

    def test_register_merges_existing_components_and_preserves_priority_when_unspecified
      decoder = decoder_for(event: "decoded")
      encoder = ->(record) { JSON.generate("event" => record.fetch(:event)) }

      with_log_formats do
        first = Core::CLI::LogFormats.register(:merge_test, decoder: decoder, priority: 17)
        second = Core::CLI::LogFormats.register(:merge_test, encoder: encoder)

        assert_same decoder, first.decoder
        assert_same decoder, second.decoder
        assert_same encoder, second.encoder
        assert_equal 17, second.priority
        assert_equal({ event: "decoded" }, Core::CLI::LogFormats.decode({}, format: :merge_test))
        assert_equal JSON.generate("event" => "encoded"),
                     Core::CLI::LogFormats.encode(build_record({ event: "encoded" }), format: :merge_test)
      end
    end

    def test_core_json_encoder_uses_internal_formatter_and_encoder
      poisoned_encoder = Class.new do
        def initialize
          raise "public alias should not be used"
        end
      end
      encoder_owner = Core::CLI::LogFormats::CoreJsonEncoder
      had_encoder = encoder_owner.instance_variable_defined?(:@json_encoder)
      previous_encoder = encoder_owner.instance_variable_get(:@json_encoder) if had_encoder
      encoder_owner.remove_instance_variable(:@json_encoder) if had_encoder

      without_constant(Julewire, :JsonEncoder) do
        Julewire.const_set(:JsonEncoder, poisoned_encoder)
        payload = JSON.parse(
          Core::CLI::LogFormats::CoreJsonEncoder.call(
            build_record({ event: "encoded" }, carry: { trace_id: "hidden" })
          )
        )

        assert_equal "encoded", payload.fetch("event")
        assert_equal "point", payload.fetch("kind")
        refute_includes payload, "carry"
      end
    ensure
      if defined?(encoder_owner) && defined?(had_encoder) && had_encoder
        encoder_owner.instance_variable_set(:@json_encoder, previous_encoder)
      elsif defined?(encoder_owner) && encoder_owner.instance_variable_defined?(:@json_encoder)
        encoder_owner.remove_instance_variable(:@json_encoder)
      end
    end

    def test_register_preserves_existing_encoder_when_decoder_is_added
      decoder = decoder_for(event: "decoded")
      encoder = ->(record) { JSON.generate("event" => record.fetch(:event)) }

      with_log_formats do
        Core::CLI::LogFormats.register(:merge_encoder_first, encoder: encoder, priority: 11)
        entry = Core::CLI::LogFormats.register(:merge_encoder_first, decoder: decoder)

        assert_same decoder, entry.decoder
        assert_same encoder, entry.encoder
        assert_equal 11, entry.priority
      end
    end

    def test_register_starts_new_entries_without_inheriting_previous_components
      with_log_formats do
        Core::CLI::LogFormats.register(:encoder_only, encoder: ->(record) { record.fetch(:event) })
        entry = Core::CLI::LogFormats.register(:decoder_only, decoder: decoder_for(event: "decoded"))

        assert_nil entry.encoder
        assert_equal 0, entry.priority
      end
    end

    def test_register_preserves_other_format_entries
      with_log_formats do
        Core::CLI::LogFormats.register(:first_decoder, decoder: decoder_for(event: "first"))
        Core::CLI::LogFormats.register(:second_decoder, decoder: decoder_for(event: "second"))

        assert_equal "first", Core::CLI::LogFormats.decode({}, format: :first_decoder).fetch(:event)
        assert_equal "second", Core::CLI::LogFormats.decode({}, format: :second_decoder).fetch(:event)
      end
    end

    def test_register_replaces_existing_priority_when_given
      assert_registered_priority_replacement(priority: 30, event: "high")
    end

    def test_register_allows_explicit_zero_priority
      assert_registered_priority_replacement(priority: 0, event: "zero")
    end

    def assert_registered_priority_replacement(priority:, event:)
      with_log_formats do
        Core::CLI::LogFormats.register(:priority_test, decoder: decoder_for(event: "high"), priority: 30)
        entry = Core::CLI::LogFormats.register(:priority_test, decoder: decoder_for(event:), priority:)

        assert_equal priority, entry.priority
        assert_equal event, Core::CLI::LogFormats.decode({}, format: :priority_test).fetch(:event)
      end
    end

    def test_register_rejects_invalid_priority
      with_log_formats do
        assert_raises(ArgumentError) do
          Core::CLI::LogFormats.register(:bad_priority, decoder: decoder_for, priority: "nope")
        end
      end
    end

    def test_register_validates_format_name_and_components
      with_log_formats do
        name_error = assert_raises(ArgumentError) { Core::CLI::LogFormats.register(:BadFormat, decoder: decoder_for) }
        empty_error = assert_raises(ArgumentError) { Core::CLI::LogFormats.normalize("") }
        type_error = assert_raises(ArgumentError) { Core::CLI::LogFormats.normalize(Object.new) }
        decoder_error = assert_raises(ArgumentError) { Core::CLI::LogFormats.register(:bad_decoder, decoder: Object.new) }
        encoder_error = assert_raises(ArgumentError) { Core::CLI::LogFormats.register(:bad_encoder, encoder: Object.new) }

        assert_equal "log format must contain lowercase letters, digits, or underscores", name_error.message
        assert_equal "log format must not be empty", empty_error.message
        assert_equal "log format must be a String or Symbol", type_error.message
        assert_equal "decoder must respond to #call", decoder_error.message
        assert_equal "encoder must respond to #call", encoder_error.message
      end
    end

    def test_auto_decode_prefers_high_priority_matching_decoder
      with_log_formats do
        Core::CLI::LogFormats.register(:low_priority, decoder: decoder_for(event: "low"), priority: 1)
        Core::CLI::LogFormats.register(:high_priority, decoder: decoder_for(event: "high"), priority: 2)

        assert_equal "high", Core::CLI::LogFormats.decode({}).fetch(:event)
      end
    end

    def test_auto_decode_ignores_encoder_only_formats
      with_log_formats do
        Core::CLI::LogFormats.register(:encoder_only, encoder: ->(_record) { "encoded" }, priority: 100)
        Core::CLI::LogFormats.register(:decoder, decoder: decoder_for(event: "decoded"), priority: 1)

        assert_equal "decoded", Core::CLI::LogFormats.decode({}).fetch(:event)
      end
    end

    def test_auto_decode_accepts_decoders_without_match_predicate
      with_log_formats do
        Core::CLI::LogFormats.register(:plain_decoder, decoder: ->(_payload) { { event: "plain" } }, priority: 100)

        assert_equal "plain", Core::CLI::LogFormats.decode({}).fetch(:event)
      end
    end

    def test_auto_decode_ignores_false_or_raising_match_predicates
      rejecting = Module.new do
        define_singleton_method(:match?) { |_payload| false }
        define_singleton_method(:call) { |_payload| { event: "rejecting" } }
      end
      raising = Module.new do
        define_singleton_method(:match?) { |_payload| raise "match failed" }
        define_singleton_method(:call) { |_payload| { event: "raising" } }
      end

      with_log_formats do
        Core::CLI::LogFormats.register(:rejecting, decoder: rejecting, priority: 100)
        Core::CLI::LogFormats.register(:raising, decoder: raising, priority: 90)
        Core::CLI::LogFormats.register(:accepted, decoder: decoder_for(event: "accepted"), priority: 1)

        assert_equal "accepted", Core::CLI::LogFormats.decode({}).fetch(:event)
      end
    end

    def test_auto_decode_rejects_when_no_decoder_accepts_payload
      decoder = Module.new do
        define_singleton_method(:match?) { |_payload| false }
        define_singleton_method(:call) { |_payload| { event: "ignored" } }
      end

      with_log_formats do
        Core::CLI::LogFormats.register(:rejecting, decoder: decoder)

        error = assert_raises(TypeError) { Core::CLI::LogFormats.decode({}) }

        assert_equal "no log decoder accepted JSON object", error.message
      end
    end

    def test_named_decode_requires_matching_decoder
      decoder = Module.new do
        define_singleton_method(:match?) { |_payload| false }
        define_singleton_method(:call) { |_payload| { event: "ignored" } }
      end

      with_log_formats do
        Core::CLI::LogFormats.register(:strict_provider, decoder: decoder)

        error = assert_raises(TypeError) { Core::CLI::LogFormats.decode({}, format: :strict_provider) }

        assert_equal "log format strict_provider did not accept JSON object", error.message
      end
    end

    def test_named_encode_and_decode_lazy_load_missing_formats
      loaded = []
      lazy_decoder = decoder_for(event: "lazy")
      lazy_encoder = ->(record) { JSON.generate("event" => record.fetch(:event)) }

      with_log_formats do
        with_overridden_singleton_method(Core::CLI::LogFormats, :load_gem_format, proc { |name|
          loaded << name
          Core::CLI::LogFormats.register(
            name,
            decoder: lazy_decoder,
            encoder: lazy_encoder
          )
        }) do
          assert_equal "lazy", Core::CLI::LogFormats.decode({}, format: :lazy_provider).fetch(:event)
          assert_equal JSON.generate("event" => "encoded"),
                       Core::CLI::LogFormats.encode(build_record({ event: "encoded" }), format: :lazy_provider)
        end
      end

      assert_equal [:lazy_provider], loaded
    end

    def test_named_encode_lazy_loads_missing_formats
      loaded = []
      lazy_encoder = ->(record) { JSON.generate("event" => record.fetch(:event)) }

      with_log_formats do
        with_overridden_singleton_method(Core::CLI::LogFormats, :load_gem_format, proc { |name|
          loaded << name
          Core::CLI::LogFormats.register(name, encoder: lazy_encoder)
        }) do
          assert_equal JSON.generate("event" => "encoded"),
                       Core::CLI::LogFormats.encode(build_record({ event: "encoded" }), format: :encode_lazy)
        end
      end

      assert_equal [:encode_lazy], loaded
    end

    def test_missing_lazy_loaded_format_reports_unavailable
      with_log_formats do
        with_overridden_singleton_method(Core::CLI::LogFormats, :load_gem_format, proc { |_name| }) do
          decode_error = assert_raises(ArgumentError) { Core::CLI::LogFormats.decode({}, format: :missing_provider) }
          encode_error = assert_raises(ArgumentError) { Core::CLI::LogFormats.encode(build_record, format: :missing_provider) }

          assert_equal "log format missing_provider is not available", decode_error.message
          assert_equal "log format missing_provider is not available", encode_error.message
        end
      end
    end

    def test_load_gem_format_ignores_missing_provider_file
      Core::CLI::LogFormats.load_gem_format(:definitely_missing_provider_for_test)
    end

    def test_load_gem_format_requires_provider_path
      with_log_formats do
        with_temp_load_path do |dir|
          format = :"required_provider_#{object_id}"
          write_provider_file(dir, format, <<~RUBY)
            Julewire::Core::CLI::LogFormats.register(#{format.inspect}, decoder: ->(_payload) { { event: "required" } })
          RUBY

          assert_equal "required", Core::CLI::LogFormats.decode({}, format: format).fetch(:event)
        end
      end
    end

    def test_load_gem_format_reraises_nested_load_errors
      with_temp_load_path do |dir|
        format = :"broken_provider_#{object_id}"
        write_provider_file(dir, format, <<~RUBY)
          require "julewire/missing_nested_dependency_for_test"
        RUBY

        error = assert_raises(LoadError) { Core::CLI::LogFormats.load_gem_format(format) }

        assert_equal "julewire/missing_nested_dependency_for_test", error.path
      end
    end

    def test_encode_normalizes_format_name
      encoded = Core::CLI::LogFormats.encode(build_record({ event: "tail.string_format" }), format: "core")

      assert_includes encoded, "tail.string_format"
    end

    def test_decode_rejects_non_object_payloads
      error = assert_raises(TypeError) { Core::CLI::LogFormats.decode([]) }

      assert_equal "log entry must be a JSON object", error.message
    end

    private

    def core_payload(message: "hello", event: "tail.event")
      {
        "timestamp" => "2026-06-19T10:00:00Z",
        "severity" => "info",
        "kind" => "point",
        "event" => event,
        "message" => message
      }
    end

    def decoder_for(event: "decoded")
      Module.new do
        define_singleton_method(:match?) { |_payload| true }
        define_singleton_method(:call) { |_payload| { event: event } }
      end
    end

    def decoder_matches?(decoder, payload)
      decoder.match?(payload)
    end

    def with_temp_load_path
      Dir.mktmpdir("julewire-log-format") do |dir|
        $LOAD_PATH.unshift(dir)
        yield dir
      ensure
        $LOAD_PATH.delete(dir)
      end
    end

    def write_provider_file(dir, format, body)
      provider_dir = File.join(dir, "julewire")
      Dir.mkdir(provider_dir)
      File.write(File.join(provider_dir, "#{format}.rb"), body)
    end
  end
end
