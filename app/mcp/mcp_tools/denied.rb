# frozen_string_literal: true

module McpTools
  # Something the user asked for that they may not do. Returned to the AI app
  # as a tool error it can read out, and audited as "denied".
  class Denied < StandardError; end
end
