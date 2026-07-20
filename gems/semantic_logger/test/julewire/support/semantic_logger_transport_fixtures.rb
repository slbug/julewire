# frozen_string_literal: true

require "tmpdir"
require "timeout"

module Julewire
  module SemanticLogger
    module SemanticLoggerTransportFixtures
      ASYNC_TEST_TIMEOUT = 0.5
      class GCPShapeFormatter
        def call(record)
          {
            severity: record.fetch(:severity).to_s.upcase,
            message: record.fetch(:message),
            labels: record.fetch(:labels, {}),
            jsonPayload: record.fetch(:payload, {})
          }
        end
      end

      class LineFormatter
        def call(record)
          { line: record.fetch(:message) }
        end
      end

      class FailingIO
        def write(_value)
          raise "write failed"
        end

        def flush; end
      end

      class FlakyIO
        attr_reader :string

        def initialize
          @failed = false
          @string = +""
        end

        def write(value)
          unless @failed
            @failed = true
            raise "write failed"
          end

          @string << value
        end

        def flush; end
      end

      class FailingLifecycleTransport
        def initialize(status: :ok)
          @status = status
        end

        def write(_payload, severity:); end

        def flush = raise("flush failed")

        def close = raise("close failed")

        def reopen = raise("reopen failed")

        def health = { status: @status }
      end

      class ForkAwareTransport
        attr_reader :after_fork_count

        def initialize
          @after_fork_count = 0
        end

        def write(_payload, severity:); end

        def flush; end

        def close; end

        def reopen; end

        def after_fork!
          @after_fork_count += 1
        end

        def health = { status: :ok }
      end

      class FailingAfterForkTransport
        def write(_payload, severity:); end

        def flush; end

        def close; end

        def reopen; end

        def after_fork! = raise("after fork failed")

        def health = { status: :ok }
      end

      class BlockingAppender < ::SemanticLogger::Subscriber
        attr_reader :concurrent

        def initialize
          super
          @mutex = Mutex.new
          @entries = Queue.new
          @releases = Queue.new
          @active = false
          @concurrent = false
        end

        def log(_log)
          @mutex.synchronize do
            @concurrent = true if @active
            @active = true
          end
          @entries << true
          @releases.pop
        ensure
          @mutex.synchronize { @active = false }
        end

        def wait_for_entry = Timeout.timeout(1) { @entries.pop }

        def entry_pending? = !@entries.empty?

        def release = @releases << true

        def flush; end

        def close; end
      end

      class RecordingAppender < ::SemanticLogger::Subscriber
        attr_reader :levels, :names

        def initialize
          super
          @levels = []
          @names = []
        end

        def log(log)
          @levels << log.level
          @names << log.name
        end

        def flush; end

        def close; end
      end

      class QueueingAppender < ::SemanticLogger::Subscriber
        def initialize
          super
          @items = Queue.new
        end

        def enqueue(item) = @items << item

        def wait_for_item = Timeout.timeout(ASYNC_TEST_TIMEOUT) { @items.pop }

        def flush; end

        def close; end
      end

      class CapturingAppender < QueueingAppender
        def log(log)
          enqueue(log)
        end

        def wait_for_entry = wait_for_item
      end

      class BatchingAppender < QueueingAppender
        def batch(logs)
          enqueue(logs)
        end

        def wait_for_batch = wait_for_item
      end

      class RaisingAppender < ::SemanticLogger::Subscriber
        attr_reader :entries

        def initialize
          super
          @entries = Queue.new
        end

        def log(log)
          @entries << log
          raise "async appender failed"
        end

        def wait_for_entry = Timeout.timeout(ASYNC_TEST_TIMEOUT) { @entries.pop }

        def flush; end

        def close; end
      end

      class ReopenlessAppender < ::SemanticLogger::Subscriber
        attr_reader :closed

        def log(_log); end

        def flush; end

        def close
          @closed = true
        end
      end
    end
  end
end
