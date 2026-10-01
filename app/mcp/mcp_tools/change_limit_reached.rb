# frozen_string_literal: true

module McpTools
  # The person's AI app made as many changes as the company allows in the
  # hour or the day. Refused like any Denied, and the admins are told.
  class ChangeLimitReached < Denied; end
end
