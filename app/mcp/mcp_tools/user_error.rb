# frozen_string_literal: true

module McpTools
  # A request that cannot be carried out as asked (bad id, unknown status).
  class UserError < StandardError; end
end
