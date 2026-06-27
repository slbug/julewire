# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module Julewire
  module Core
    module TestHelpers
      CLIResult = Data.define(:status, :stdout, :stderr)
      CLI_THREAD_TIMEOUT = 0.2

      def reset_julewire!
        Julewire.reset!
      end

      def capture_julewire_records
        Julewire::Testing.capture { yield it if block_given? }
      end

      def assert_runtime_call_rejected_inside_configure(method_name, &)
        error = assert_raises(Julewire::Core::Error) do
          Julewire.configure(&)
        end

        assert_equal "Julewire.#{method_name} cannot be called from inside Julewire.configure", error.message
      end

      def in_temporary_repo(&)
        Dir.mktmpdir("julewire-test") { |dir| Dir.chdir(dir, &) }
      end

      def write_temporary_repo_file(path, content)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end

      def configure_record_capture(level: nil, processors: [])
        records = []

        Julewire.configure do |config|
          config.level = level if level
          configure_destination(
            config,
            formatter: RecordCaptureFormatter.new(records),
            output: Julewire::Testing::NullOutput.new
          )
          Array(processors).each { config.processors.use(it) }
        end

        records
      end

      def configure_output_with_drop_capture(output)
        drops = Queue.new

        Julewire.configure do |config|
          configure_destination(config, output: output)
          config.on_drop = ->(reason, metadata) { drops << [reason, metadata] }
        end

        drops
      end

      def configure_default_output(output)
        Julewire.configure { configure_destination(it, output: output) }
      end

      def assert_configure_with_default_output_raises(error_class = ArgumentError)
        assert_raises(error_class) do
          Julewire.configure do |config|
            configure_destination(config, output: StringIO.new)
            yield config
          end
        end
      end

      def build_execution_scope(**)
        Core::Execution::Scope.new(**)
      end

      def normalized_record(**overrides)
        Core::Records::Record::REQUIRED_KEYS.to_h { [it, normalized_record_default(it)] }.merge(overrides)
      end

      def fixture_truncation_metadata
        {
          truncated: true,
          truncated_fields: ["ids"],
          limits: {
            max_array_items: nil,
            max_depth: 20,
            max_hash_keys: nil,
            max_string_bytes: 10
          }
        }
      end

      def normalized_record_default(key)
        case key
        when :timestamp then Time.now.utc
        when :severity then :info
        when :kind then :point
        when :event then "log"
        when :message, :logger, :source, :error then nil
        else {}
        end
      end

      def run_cli(argv, input: "", timeout: CLI_THREAD_TIMEOUT)
        stdout = StringIO.new
        stderr = StringIO.new
        thread = safe_thread do
          status = Julewire::Core::CLI.call(
            argv: argv,
            stdin: StringIO.new(input),
            stdout: stdout,
            stderr: stderr
          )
          CLIResult.new(status: status, stdout: stdout.string, stderr: stderr.string)
        end
        safe_thread_value(thread, timeout: timeout)
      ensure
        cleanup_thread(thread, timeout: 0)
      end

      def tail_line(message:, event:)
        JSON.generate(
          "timestamp" => "2026-06-19T10:00:00Z",
          "severity" => "info",
          "kind" => "point",
          "event" => event,
          "message" => message,
          "source" => "test",
          "execution" => {},
          "context" => {},
          "attributes" => {}
        )
      end

      def with_monotonic_times(*values, &)
        times = Queue.new
        values.each { times << it }
        clock_gettime = Process.method(:clock_gettime)
        with_overridden_singleton_method(
          Process,
          :clock_gettime,
          proc do |clock, *args|
            clock == Process::CLOCK_MONOTONIC ? times.pop : clock_gettime.call(clock, *args)
          end,
          &
        )
      end

      def without_constant(owner, name)
        existed = owner.const_defined?(name, false)
        original = owner.const_get(name, false) if existed
        owner.__send__(:remove_const, name) if existed
        yield
      ensure
        restore_constant(owner, name, existed, original)
      end

      def with_temporary_constant(owner, name, value)
        existed = owner.const_defined?(name, false)
        original = owner.const_get(name, false) if existed
        owner.__send__(:remove_const, name) if existed
        owner.const_set(name, value)
        yield
      ensure
        restore_constant(owner, name, existed, original)
      end

      def restore_constant(owner, name, existed, original)
        owner.__send__(:remove_const, name) if owner.const_defined?(name, false)
        owner.const_set(name, original) if existed
      end

      def with_log_formats
        original = Core::CLI::LogFormats.instance_variable_get(:@entries)
        yield
      ensure
        Core::CLI::LogFormats.instance_variable_set(:@entries, original)
      end

      def configure_runtime_failure_capture(runtime, output: StringIO.new)
        failures = Queue.new
        runtime.configure do |config|
          configure_destination(config, output: output)
          config.on_failure = ->(error, metadata) { failures << [error, metadata] }
        end
        failures
      end

      def configure_destination(config, output:, **options)
        name = options.fetch(:name, :default)
        config.destinations.clear if name == :default
        destination_options = {
          close_output: options.fetch(:close_output, false),
          max_record_bytes: options.fetch(:max_record_bytes, DEFAULT_MAX_RECORD_BYTES),
          output: output
        }
        destination_options[:encoder] = options.fetch(:encoder) if options.key?(:encoder)
        destination_options[:formatter] = options.fetch(:formatter) if options.key?(:formatter)
        destination_options[:on_drop] = options.fetch(:on_drop) if options.key?(:on_drop)
        destination_options[:on_failure] = options.fetch(:on_failure) if options.key?(:on_failure)
        destination_options[:processors] = options.fetch(:processors) if options.key?(:processors)

        config.destinations.use(name, **destination_options)
      end

      class RecordCaptureFormatter
        def initialize(records)
          @records = records
        end

        def call(record)
          @records << Fields::FieldSet.deep_dup(record)
          {}
        end
      end

      class TestLineFormatter
        def initialize(prefix)
          @prefix = prefix
        end

        def call(record)
          { line: "#{@prefix}:#{record.fetch(:message)}" }
        end
      end
    end
  end
end
