# frozen_string_literal: true

module Julewire
  module Core
    module Scheduling
      # @api integration_spi
      class DeadlineScheduler
        CLOCK = Process::CLOCK_MONOTONIC
        Entry = Data.define(:deadline, :token, :callback)

        def initialize(thread_name:, idle: :keep_alive)
          @thread_name = thread_name
          @idle = idle
          @mutex = Mutex.new
          @condition = ConditionVariable.new
          @entries = {}
          # A heap keeps timeout scheduling cheap without non-shareable scheduler dependencies.
          @heap = []
          @next_token = 0
          @generation = 0
          @pid = Process.pid
          @thread = nil
        end

        def schedule(timeout, &block)
          raise ArgumentError, "block required" unless block

          timeout = Float(timeout)
          if timeout <= 0
            yield
            return
          end

          @mutex.synchronize do
            token = next_token
            entry = Entry.new(monotonic_time + timeout, token, block)
            @entries[token] = entry
            heap_push(entry)
            ensure_thread
            @condition.signal
            token
          end
        end

        def cancel(token)
          return unless token

          @mutex.synchronize do
            @entries.delete(token)
            @condition.signal
          end
        end

        def after_fork!
          if @pid == Process.pid
            reset_same_process
          else
            reset_after_fork
          end

          self
        end

        private

        def reset_same_process
          @mutex.synchronize do
            @generation += 1
            @entries = {}
            @heap = []
            @next_token = 0
            @thread = nil
            @condition.broadcast
          end
        end

        def reset_after_fork
          @mutex = Mutex.new
          @condition = ConditionVariable.new
          @entries = {}
          @heap = []
          @next_token = 0
          @generation += 1
          @pid = Process.pid
          @thread = nil
        end

        def next_token
          @next_token += 1
        end

        def ensure_thread
          return if @thread&.alive?

          generation = @generation
          @thread = Thread.new { run(generation) }
          @thread.name = @thread_name
          @thread.report_on_exception = false
        end

        def run(generation)
          loop do
            callback = next_expired_callback(generation)
            return unless callback

            safe_call(callback)
          end
        end

        def next_expired_callback(generation)
          @mutex.synchronize do
            loop do
              return unless generation == @generation

              discard_cancelled_head
              if @heap.empty?
                return clear_thread if exit_when_idle?

                @condition.wait(@mutex)
                next
              end

              entry = @heap.fetch(0)
              remaining = entry.deadline - monotonic_time
              if remaining.positive?
                @condition.wait(@mutex, remaining)
              else
                heap_pop
                @entries.delete(entry.token)
                return entry.callback
              end
            end
          end
        end

        def discard_cancelled_head
          heap_pop while @heap.any? && !@entries.key?(@heap.fetch(0).token)
        end

        def clear_thread
          @thread = nil
          nil
        end

        def exit_when_idle?
          @idle == :exit
        end

        def safe_call(callback)
          callback.call
        rescue StandardError
          nil
        end

        def monotonic_time
          Process.clock_gettime(CLOCK)
        end

        def heap_push(entry)
          @heap << entry
          sift_up(@heap.length - 1)
        end

        def heap_pop
          return @heap.pop if @heap.one?

          top = @heap.fetch(0)
          @heap[0] = @heap.pop
          sift_down(0)
          top
        end

        def sift_up(index)
          while index.positive?
            parent = (index - 1) / 2
            break if earlier_or_equal?(@heap.fetch(parent), @heap.fetch(index))

            swap_heap(index, parent)
            index = parent
          end
        end

        def sift_down(index)
          loop do
            left = (index * 2) + 1
            right = left + 1
            smallest = index
            smallest = left if left < @heap.length && earlier_or_equal?(@heap.fetch(left), @heap.fetch(smallest))
            smallest = right if right < @heap.length && earlier_or_equal?(@heap.fetch(right), @heap.fetch(smallest))
            break if smallest == index

            swap_heap(index, smallest)
            index = smallest
          end
        end

        def earlier_or_equal?(left, right)
          left.deadline < right.deadline || (left.deadline == right.deadline && left.token <= right.token)
        end

        def swap_heap(left, right)
          @heap[left], @heap[right] = @heap[right], @heap[left]
        end
      end
    end
  end
end
