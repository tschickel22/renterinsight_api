# frozen_string_literal: true

module McpTools
  # Who a tool call runs as: one user, at the one company their grant names.
  #
  # Permission checks reproduce ApplicationController#can? for that user,
  # minus the platform admin branches (platform admins cannot connect, see
  # Oauth::AccessPolicy). Location access deliberately differs from the
  # controllers in one way: a non-admin RBAC user with no locations sees
  # nothing here, where most controllers fall back to the whole company.
  class Context
    MAX_ROWS = 50
    DEFAULT_DAILY_RECORD_LIMIT = 2_000

    attr_reader :user, :company, :grant, :ip_address

    def initialize(user:, company:, grant:, ip_address: nil)
      @user = user
      @company = company
      @grant = grant
      @ip_address = ip_address
    end

    # ServerContext forwards unknown methods to the object it wraps, so tools
    # reach this through `server_context.mcp_context`.
    def mcp_context
      self
    end

    def rbac?
      company.use_rbac_system
    end

    def admin?
      return @admin if defined?(@admin)

      @admin = user.effective_admin? || company_admin_assignment?
    end

    def can?(resource, action, scope = 'all')
      return false unless user.active?

      if rbac?
        return true if user.company_admin?
        return true if user.has_permission?(resource, action, scope, company.id)

        company_admin_assignment?
      else
        return true if user.admin? || user.tenant?

        case action
        when 'read', 'export' then true
        when 'create', 'update' then user.staff? || user.admin?
        else user.admin?
        end
      end
    end

    def authorize!(resource, action)
      return if can?(resource, action)

      raise Denied, "Your role does not allow #{action} on #{resource.tr('_', ' ')}."
    end

    def require_scope!(scope)
      return if grant.scope_list.include?(scope)

      raise Denied, 'This connection was approved for reading only. Reconnect and allow changes to do this.'
    end

    # nil means every location in the company.
    def location_ids
      return @location_ids if defined?(@location_ids)

      @location_ids =
        if !rbac? || admin?
          nil
        else
          user.accessible_locations.where(company_id: company.id).pluck(:id)
        end
    end

    def scope_locations(relation, include_unlocated: false)
      ids = location_ids
      return relation if ids.nil?
      return relation.none if ids.empty?

      table = relation.klass.arel_table
      condition = table[:location_id].in(ids)
      condition = condition.or(table[:location_id].eq(nil)) if include_unlocated
      relation.where(condition)
    end

    def location_allowed?(location_id)
      return company.locations.exists?(id: location_id) if location_ids.nil?

      location_ids.include?(location_id.to_i)
    end

    def default_location_id
      location_ids&.first
    end

    # Exfiltration guard: a per user, per day budget of records returned by
    # list and search tools, on top of the per call cap. Company 17 took
    # 9,703 leads on its way out; this connector is another door and is
    # treated as one.
    def daily_record_limit
      settings = Setting.get('Company', company.id, 'mcp_settings', {}) || {}
      (settings['daily_record_limit'] || DEFAULT_DAILY_RECORD_LIMIT).to_i
    end

    def records_used_today
      McpToolCall.where(user_id: user.id, company_id: company.id, created_at: Time.current.beginning_of_day..)
                 .sum(:result_count)
    end

    def row_limit(requested)
      remaining = daily_record_limit - records_used_today
      if remaining <= 0
        raise Denied, "Daily limit of #{daily_record_limit} records reached for this connection. It resets at midnight."
      end

      [[requested.to_i.positive? ? requested.to_i : 20, MAX_ROWS].min, remaining].min
    end

    def app_url(path)
      "#{Brand.app_url(company: company).to_s.chomp('/')}#{path}"
    end

    def location_names
      @location_names ||= company.locations.pluck(:id, :name).to_h
    end

    def user_names
      @user_names ||= company.users.pluck(:id, :first_name, :last_name).to_h { |id, f, l| [id, "#{f} #{l}".strip] }
    end

    def audit!(tool_name:, arguments:, status:, result_count:, duration_ms:, error_message:)
      McpToolCall.create!(
        oauth_grant_id: grant&.id, user_id: user.id, company_id: company.id,
        client_name: grant&.oauth_client&.client_name, tool_name: tool_name,
        arguments: self.class.redact(arguments), status: status, result_count: result_count,
        duration_ms: duration_ms, error_message: error_message.to_s.first(500).presence, created_at: Time.current
      )
    rescue StandardError => e
      Rails.logger.error("[McpTools] audit write failed: #{e.class}: #{e.message}")
    end

    # Keep what was asked for, not a copy of what was written: long text
    # (note bodies, descriptions) is cut to a preview.
    def self.redact(arguments)
      arguments.to_h.transform_keys(&:to_s).transform_values do |value|
        value.is_a?(String) && value.length > 120 ? "#{value.first(120)}..." : value
      end
    end

    private

    def company_admin_assignment?
      return false unless rbac?

      user.user_role_assignments.joins(:role)
          .where(company_id: company.id, roles: { tier: 'company' })
          .where(roles: { key: %w[company_admin admin super_admin] }).exists?
    end
  end
end
