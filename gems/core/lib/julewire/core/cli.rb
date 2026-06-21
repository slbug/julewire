# frozen_string_literal: true

module Julewire
  module Core
    class CLI
      INTERRUPTED_STATUS = 130

      class << self
        def call(argv: ARGV, stdin: $stdin, stdout: $stdout, stderr: $stderr)
          new(argv: argv, stdin: stdin, stdout: stdout, stderr: stderr).call
        end
      end

      def initialize(argv:, stdin:, stdout:, stderr:)
        @argv = argv.dup
        @stdin = stdin
        @stdout = stdout
        @stderr = stderr
      end

      def call
        case command = @argv.shift
        when "tail" then tail
        when "transcode" then transcode
        when "doctor" then doctor
        when "-v", "--version", "version" then version
        when nil, "-h", "--help", "help" then help
        else
          fail_with("unknown command #{command.inspect}")
        end
      rescue Interrupt
        INTERRUPTED_STATUS
      rescue ArgumentError, Errno::ENOENT => e
        fail_with(e.message)
      end

      private

      def tail
        Tail.new(argv: @argv, stdin: @stdin, stdout: @stdout).call
      end

      def transcode
        Transcode.new(argv: @argv, stdin: @stdin, stdout: @stdout).call
      end

      def doctor
        Doctor.new(argv: @argv, stdout: @stdout).call
      end

      def version
        @stdout.write("julewire #{Core::VERSION}\n")
        0
      end

      def help
        @stdout.write(<<~HELP)
          Usage:
            julewire tail [--follow|--once] [--format auto|core|NAME] [--skip-invalid|--raw-invalid] [--color|--no-color] [--theme plain|punk|--plain|--punk] [--limit N] [--max-value-bytes N] LOGFILE|-
            julewire transcode [--from auto|core|NAME] [--to core|console|NAME] [--skip-invalid|--raw-invalid] [--color|--no-color] [--theme plain|punk|--plain|--punk] [--max-value-bytes N] LOGFILE|-
            julewire doctor [--json|--text|--punk] [--color|--no-color]
            julewire --version
        HELP
        0
      end

      def fail_with(message)
        @stderr.write("julewire: #{message}\n")
        1
      end
    end
  end
end
