# frozen_string_literal: true

require "json"
require "stringio"
require "timeout"

module Julewire
  class ReplyingPort
    attr_reader :messages

    def initialize(reply: "ok")
      @messages = []
      @reply = reply
    end

    def send(message)
      @messages << message
      message[:reply]&.send(@reply)
    end
  end

  class FailingPort
    def send(_message)
      raise "port failed"
    end
  end

  class FailingReply
    def send(_message)
      raise "reply failed"
    end
  end

  class ReplyProbe
    attr_reader :messages

    def initialize
      @messages = []
    end

    def send(message)
      @messages << message
    end
  end

  class NeverReplyingPort
    attr_reader :messages

    def initialize
      @messages = []
    end

    def send(message)
      @messages << message
    end
  end

  class RequestFailingPort
    attr_reader :reply

    def send(message)
      @reply = message.fetch(:reply)
      raise "request failed"
    end
  end

  class QueueingOutput
    def initialize
      @queue = Queue.new
    end

    def write(value) # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy write results.
      @queue << value
      true
    end

    def pop = Timeout.timeout(1) { @queue.pop }
  end

  class RactorPortOutput
    def initialize(port)
      @port = port
      @closed = false
    end

    def write(value) # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy write results.
      @port.send(value)
      true
    end

    def flush # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy flush results.
      @port.send(:flushed)
      true
    end

    def close # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy close results.
      @closed = true
      @port.send(:closed)
      true
    end

    def closed? = @closed
  end

  module DroppingRactorDestinationHelper
    def dropping_ractor_destination
      port = ::Ractor::Port.new
      drops = Queue.new
      destination = Julewire::Ractor::Destination.new(
        output: RactorPortOutput.new(port),
        on_drop: ->(reason, _metadata) { drops << reason }
      )
      [port, drops, destination]
    end
  end

  module RactorRecordHelper
    def record(message:, payload: {}, **fields)
      Julewire::Core::Records::Draft.build(
        { message: message, payload: payload }.merge(fields),
        context: {},
        scope: nil
      ).to_record
    end
  end

  module RactorWaitHelper
    def wait_until
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
      until yield
        flunk "condition did not become true" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        Thread.pass
      end
    end
  end

  class SlowRactorPortOutput
    def initialize(write_port, sleep_seconds: 0.5)
      @write_port = write_port
      @sleep_seconds = sleep_seconds
    end

    def write(value) # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy write results.
      @write_port.send(value)
      sleep @sleep_seconds
      true
    end
  end

  class SlowFlushRactorPortOutput
    def initialize(port, sleep_seconds: 0.5)
      @port = port
      @sleep_seconds = sleep_seconds
    end

    def write(_value) = true # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy write results.

    def flush # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy flush results.
      @port.send(:flushing)
      sleep @sleep_seconds
      true
    end
  end

  class BlockingCloseOutput
    def initialize(entered_port, release_io)
      @entered_port = entered_port
      @release_io = release_io
      @closed = false
    end

    def write(_value) = true # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy write results.

    def close # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy close results.
      @entered_port.send(:closing)
      @release_io.gets
      @closed = true
      true
    end

    def closed? = @closed
  end

  class RejectingRactorPortOutput
    def initialize(write_port)
      @write_port = write_port
    end

    def write(value) # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy write results.
      @write_port.send(value)
      false
    end
  end

  class RejectingCloseRactorPortOutput < RactorPortOutput
    def close # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy close results.
      @port.send(:close_rejected)
      false
    end
  end

  class StaticEncoder
    def initialize(payload)
      @payload = payload
    end

    def call(_record) = @payload
  end

  class NonCopyableOutput
    def initialize
      @callback = -> {}
    end

    def write(_value) # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy write results.
      true
    end
  end
end
