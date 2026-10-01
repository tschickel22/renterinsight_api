# frozen_string_literal: true

# One row per MCP tool call. Arguments are stored with free-text values cut
# short, so the audit shows what was asked for without becoming a second copy
# of customer data.
class McpToolCall < ApplicationRecord
  belongs_to :oauth_grant, optional: true
  belongs_to :user
  belongs_to :company
end
