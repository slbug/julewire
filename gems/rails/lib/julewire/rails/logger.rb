# frozen_string_literal: true

require "active_support/isolated_execution_state"
require "logger"

module Julewire
  module Rails
    class Logger
      FORGED_RECORD_KEYS = %i[kind execution carry attributes neutral].freeze
      RECORD_KEYS = (Julewire::Core::Fields::Bags.required_record_keys - FORGED_RECORD_KEYS).freeze
      private_constant :FORGED_RECORD_KEYS, :RECORD_KEYS

      attr_accessor :datetime_format, :formatter, :progname

      def initialize(name: "Rails", source: "rails")
        @level = ::Logger::DEBUG
        @progname = name
        @source = source
        @local_level_key = :"julewire_rails_logger_level_#{object_id}"
      end

      def add(severity, message = nil, progname = nil) # rubocop:disable Naming/PredicateMethod -- Logger API.
        severity ||= ::Logger::UNKNOWN
        return true if severity < level
        return true if Suppression.active?

        message, progname = resolve_message_and_progname(message, progname) { block_given? ? yield : nil }
        Core::RuntimeLocator.current.emit_without_level(record_for(severity, message, progname))
        true
      end

      def <<(message)
        add(::Logger::UNKNOWN, message)
      end

      def debug(progname = nil, &) = add(::Logger::DEBUG, nil, progname, &)

      def info(progname = nil, &) = add(::Logger::INFO, nil, progname, &)

      def warn(progname = nil, &) = add(::Logger::WARN, nil, progname, &)

      def error(progname = nil, &) = add(::Logger::ERROR, nil, progname, &)

      def fatal(progname = nil, &) = add(::Logger::FATAL, nil, progname, &)

      def unknown(progname = nil, &) = add(::Logger::UNKNOWN, nil, progname, &)

      def debug? = level <= ::Logger::DEBUG

      def info? = level <= ::Logger::INFO

      def warn? = level <= ::Logger::WARN

      def error? = level <= ::Logger::ERROR

      def fatal? = level <= ::Logger::FATAL

      def unknown? = level <= ::Logger::UNKNOWN

      def debug! = self.level = ::Logger::DEBUG

      def info! = self.level = ::Logger::INFO

      def warn! = self.level = ::Logger::WARN

      def error! = self.level = ::Logger::ERROR

      def fatal! = self.level = ::Logger::FATAL

      def level
        local_level || @level
      end

      def level=(value)
        @level = normalize_level(value)
      end

      def local_level
        ::ActiveSupport::IsolatedExecutionState[@local_level_key]
      end

      def local_level=(value)
        if value.nil?
          ::ActiveSupport::IsolatedExecutionState.delete(@local_level_key)
        else
          ::ActiveSupport::IsolatedExecutionState[@local_level_key] = normalize_level(value)
        end
      end

      def silence(severity = ::Logger::ERROR)
        previous_level = local_level
        self.local_level = severity
        yield self
      ensure
        self.local_level = previous_level
      end

      def close = flush

      def reopen(*) = flush

      def flush
        formatter.clear_tags! if formatter.respond_to?(:clear_tags!)
        Julewire.flush
      end

      def initialize_copy(other)
        super
        @progname = other.progname.is_a?(String) ? other.progname.dup : other.progname
        @local_level_key = :"julewire_rails_logger_level_#{object_id}"
      end

      private

      def normalize_level(value)
        case value
        when Integer
          value
        when Symbol, String
          ::Logger::Severity.const_get(value.to_s.upcase)
        else
          raise ArgumentError, "invalid log level: #{value.inspect}"
        end
      rescue NameError
        raise ArgumentError, "invalid log level: #{value.inspect}"
      end

      def resolve_message_and_progname(message, progname)
        return [message, progname || self.progname] unless message.nil?

        block_message = yield
        return [block_message, progname || self.progname] unless block_message.nil?

        [progname, self.progname]
      end

      def record_for(severity, message, progname)
        record = message.is_a?(Hash) ? structured_message(message) : scalar_message(message)
        record[:severity] = Julewire::Core::Records::Severity.severity_symbol(severity) || :unknown
        record[:logger] ||= (progname || self.progname).to_s
        record[:source] ||= @source
        merge_current_tags(record)
      end

      def scalar_message(message)
        case message
        when Exception
          { message: "#{message.class}: #{message.message}", error: message }
        else
          { message: message.to_s }
        end
      end

      def structured_message(message)
        fields = Julewire::Core::Fields::FieldSet.deep_symbolize_keys(message)
        record = fields.slice(*RECORD_KEYS)
        payload = fields.except(*RECORD_KEYS)

        unless payload.empty?
          record[:payload] = Julewire::Core::Fields::FieldSet.merge(payload_hash(record[:payload]), payload)
        end
        record
      end

      def payload_hash(payload)
        return {} if payload.nil?
        return payload if payload.is_a?(Hash)

        { Julewire::Core::Fields::FieldSet::VALUE_KEY => payload }
      end

      def merge_current_tags(record)
        current_tags = formatter.respond_to?(:current_tags) ? formatter.current_tags : nil
        return record if current_tags.nil? || current_tags.empty?

        attributes = record[:attributes].is_a?(Hash) ? record[:attributes] : {}
        rails = attributes[:rails].is_a?(Hash) ? attributes[:rails] : {}
        rails[:tags] = Julewire::Core::Fields::FieldSet.deep_dup(current_tags)
        attributes[:rails] = rails
        record[:attributes] = attributes
        record
      end
    end
  end
end
