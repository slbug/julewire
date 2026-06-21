# frozen_string_literal: true

require_relative "contracts/component"
require_relative "contracts/deadline_scheduler"
require_relative "contracts/integration"
require_relative "contracts/record_draft"
require_relative "contracts/runtime"
require_relative "contracts/wire"

module Julewire
  module Core
    module Testing
      # @api extension
      module Contracts
        include Component
        include DeadlineScheduler
        include Integration
        include RecordDraft
        include Runtime
        include Wire
      end
    end
  end
end
