# frozen_string_literal: true

module Guide
  # The Claude connector's read tools, run for the in-app help assistant
  # (E118). Same person, same permissions and locations as the connector's
  # McpTools::Context, which copies the app's own checks. Three things differ,
  # because this is the app and not an outside AI app:
  #
  # 1. Cost follows the app's permission, not the dealer's "Let AI apps see
  #    dealer cost" switch, which is about Claude and ChatGPT outside the app.
  #    Deal cost needs deals:read:view_cost_details, as the deal screen does.
  # 2. Rows are budgeted per question (ROWS_PER_QUESTION), not against the
  #    connector's daily record budget, which counts McpToolCall rows.
  # 3. Nothing is written to mcp_tool_calls. The question's own ai_query_logs
  #    row records which tools ran (Guide::Assistant#trace).
  #
  # Read only: the scopes never include mcp:write, and Guide::LookUp only
  # offers tools marked read_only!.
  class AppContext < McpTools::Context
    ROWS_PER_QUESTION = 60
    ROWS_PER_CALL = 20

    attr_reader :rows_used

    def initialize(user:, company:)
      super(user: user, company: company, grant: nil, scopes: ['mcp:read'])
      @rows_used = 0
    end

    # The app lets platform and super admins do everything (ApplicationController#can?);
    # the connector does not, because they cannot connect it. Help follows the app.
    def can?(resource, action, scope = 'all')
      return true if user&.platform_admin? || user&.super_admin?

      super
    end

    def show_costs?
      true
    end

    def book_costs_visible?
      true
    end

    def unit_costs_visible?
      true
    end

    def deal_costs_visible?
      if rbac?
        user.company_admin? || user.has_permission?('deals', 'read', scope: 'view_cost_details')
      else
        true
      end
    end

    def used!(count)
      @rows_used += count.to_i
    end

    def check_read_budget!
      remaining = ROWS_PER_QUESTION - @rows_used
      return remaining if remaining.positive?

      raise McpTools::LimitReached, 'That is as many records as I can read for one question. Ask about fewer records, ' \
                                    'or use the AI Assistant (the sparkle) for a report.'
    end

    def row_limit(requested)
      remaining = check_read_budget!
      [[requested.to_i.positive? ? requested.to_i : 10, ROWS_PER_CALL].min, remaining].min
    end

    def audit!(**)
      nil
    end
  end
end
