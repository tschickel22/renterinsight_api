# frozen_string_literal: true

module McpTools
  # The connector's areas beyond the CRM. Each is a module (AccountingArea,
  # BudgetArea...) that lists READ_TOOLS, WRITE_TOOLS and PROMPTS, and answers
  # the Undo handler calls for the records its tools change:
  #
  #   handles?(record)               true for records this area undoes
  #   label(record_type)             "budget", or nil when not this area's
  #   undo_created(change, record)   Undo::Result
  #   undo_updated(change, record)   Undo::Result
  module Areas
    NAMES = %w[
      McpTools::AccountingArea
      McpTools::BudgetArea
      McpTools::ProjectArea
      McpTools::CommissionArea
    ].freeze

    # constantize, not safe_constantize: an area that fails to load must
    # fail loudly, not quietly drop its tools from the connector.
    def self.all
      NAMES.map(&:constantize)
    end
  end
end
