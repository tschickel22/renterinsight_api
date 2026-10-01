# frozen_string_literal: true

module McpTools
  # The daily record budget is spent. A Denied like any other for the AI app,
  # but it also tells the company admins (see McpTools::Alerts).
  class LimitReached < Denied; end
end
