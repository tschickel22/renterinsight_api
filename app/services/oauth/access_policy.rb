# frozen_string_literal: true

module Oauth
  # Whether a grant may still be used right now. Checked when tokens are issued
  # and on every MCP request, so a suspended company, a deactivated user or a
  # removed add-on cuts the AI app off on its next call, not when its token
  # happens to expire.
  module AccessPolicy
    MODULE_KEY = 'admin.ai_connector'

    module_function

    # Returns nil when usable, or a short reason.
    def denial_reason(grant)
      return 'This connection was revoked.' unless grant&.active?
      return 'This user is no longer active.' unless grant.user&.active?
      return 'This account is not active.' if grant.company.nil? || grant.company.access_blocked?
      return 'The AI connector is not enabled for this company.' unless module_enabled?(grant.company)
      return 'This user no longer belongs to the company that was connected.' unless grant.user.company_id == grant.company_id
      return "This person's role no longer allows the AI connector." unless permitted?(grant.user, grant.company)

      nil
    end

    # The ai_connector permission: 'read' to connect at all, 'update' to let
    # the AI make changes. A company without RBAC has no roles to grant it
    # through, so there it is admins only. Checked on every request, so taking
    # it off a role cuts those people's apps off on their next call.
    def permitted?(user, company, action = 'read')
      ctx = McpTools::Context.new(user: user, company: company, grant: nil)
      return ctx.admin? unless company.use_rbac_system

      ctx.can?('ai_connector', action)
    end

    def changes_permitted?(user, company)
      permitted?(user, company, 'update')
    end

    def module_enabled?(company)
      ModuleAccessService.new(company).has_module?(MODULE_KEY)
    end

    # Platform and super admins act across tenants and switch company by
    # header; a token pinned to one company would quietly carry that power
    # into an AI app. They connect with a company user instead.
    def user_may_connect?(user)
      user.present? && user.active? && !user.platform_admin? && !user.super_admin? && user.company_id.present?
    end
  end
end
