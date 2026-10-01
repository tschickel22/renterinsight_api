# frozen_string_literal: true

module McpTools
  # Plan and permission checks for the marketing tools, and the wording the AI
  # repeats when something has to happen in the app instead. Workflows and
  # campaigns are only ever saved as drafts through the connector: activating,
  # scheduling, starting and sending stay with a person in DealerTide.
  module MarketingAccess
    WORKFLOW_MODULES = %w[management.workflows marketing.automation].freeze
    CAMPAIGN_MODULES = %w[marketing.campaigns marketing.automation].freeze

    module_function

    def require_workflows!(ctx, action)
      unless modules?(ctx, WORKFLOW_MODULES)
        raise Denied, "Workflow Automation is not part of this account's plan, so I cannot read or build workflows."
      end

      ctx.authorize!('workflow_automation', action)
    end

    def require_campaigns!(ctx, action)
      unless modules?(ctx, CAMPAIGN_MODULES)
        raise Denied, "Email and text campaigns are not part of this account's plan, so I cannot read or build them."
      end

      ctx.authorize!('campaigns', action)
    end

    def modules?(ctx, keys)
      service = ModuleAccessService.new(ctx.company)
      keys.any? { |key| service.has_module?(key) }
    end

    def workflow_url(ctx, rule)
      ctx.app_url("/workflow-automation/rules/#{rule.id}")
    end

    def campaign_url(ctx, campaign)
      ctx.app_url("/campaigns/#{campaign.id}")
    end

    def workflow_activation_note(ctx, rule)
      "Saved as a DRAFT. It will not run until someone activates it in DealerTide: open #{workflow_url(ctx, rule)}, " \
        'review the steps, then click Activate. Tell the user this; I cannot activate workflows.'
    end

    def campaign_activation_note(ctx, campaign)
      "Saved as a DRAFT. Nothing will be sent until someone starts it in DealerTide: open #{campaign_url(ctx, campaign)}, " \
        'check the audience, sender and content, then click Start (or schedule it there). Tell the user this; ' \
        'I cannot start, schedule or send campaigns, and I cannot send test messages.'
    end
  end
end
