# frozen_string_literal: true

# A record an AI app created or changed through the MCP connector, with what
# it looked like before and after. See McpTools::Undo.
class McpChange < ApplicationRecord
  belongs_to :mcp_tool_call, optional: true
  belongs_to :oauth_grant, optional: true
  belongs_to :user
  belongs_to :company

  scope :not_undone, -> { where(undone_at: nil) }

  def record
    record_type.safe_constantize&.find_by(id: record_id)
  end
end
