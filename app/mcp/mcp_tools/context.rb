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
    DEFAULT_HOURLY_CHANGE_LIMIT = 30
    DEFAULT_DAILY_CHANGE_LIMIT = 200

    attr_reader :user, :company, :grant, :ip_address

    # scopes: what the access token carries, which a refresh may have narrowed
    # below the grant. Defaults to the grant's for callers without a token.
    def initialize(user:, company:, grant:, scopes: nil, ip_address: nil)
      @user = user
      @company = company
      @grant = grant
      @scopes = scopes || grant&.scope_list || []
      @ip_address = ip_address
    end

    def write_allowed?
      @scopes.include?('mcp:write')
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
      return if @scopes.include?(scope)

      raise Denied, 'This connection was approved for reading only. Reconnect and allow changes to do this.'
    end

    # nil means every location in the company.
    def location_ids
      return @location_ids if defined?(@location_ids)

      @location_ids =
        if !rbac? || admin? || company_tier_role?
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
    def mcp_settings
      @mcp_settings ||= Setting.get('Company', company.id, 'mcp_settings', {}) || {}
    end

    def daily_record_limit
      (mcp_settings['daily_record_limit'] || DEFAULT_DAILY_RECORD_LIMIT).to_i
    end

    # Dealer cost through the connector (Tom, 2026-10-01: dealers want reps to
    # understand margin). Off unless the dealer turns it on under Settings, AI
    # Apps; when on, a person sees through the AI exactly what they see in the
    # app: deal costs by the same permission call the deals screen makes (its
    # quirks included), inventory costs for anyone who can read inventory, as
    # the inventory screen does.
    def show_costs?
      mcp_settings['show_costs'] == true
    end

    def deal_costs_visible?
      show_costs? && user.has_permission?('deals', 'read', scope: 'view_cost_details')
    end

    def unit_costs_visible?
      show_costs?
    end

    def hourly_change_limit
      (mcp_settings['hourly_change_limit'] || DEFAULT_HOURLY_CHANGE_LIMIT).to_i
    end

    def daily_change_limit
      (mcp_settings['daily_change_limit'] || DEFAULT_DAILY_CHANGE_LIMIT).to_i
    end

    # Writes are limited per person, by tool call (a status change with its
    # note is one change), so an AI told to "mark every lead lost" stops after
    # a handful instead of working through the whole book one record at a
    # time. Each change is allowed on its own; five hundred in a row is not.
    def changes_made_since(time)
      McpChange.where(user_id: user.id, company_id: company.id, created_at: time..).distinct.count(:mcp_tool_call_id)
    end

    def check_change_limit!
      if changes_made_since(1.hour.ago) >= hourly_change_limit
        raise ChangeLimitReached, "Change limit reached: #{hourly_change_limit} changes an hour for this person. " \
                                  'Try again later, or ask an admin to raise it.'
      end
      return unless changes_made_since(Time.current.beginning_of_day) >= daily_change_limit

      raise ChangeLimitReached, "Change limit reached: #{daily_change_limit} changes a day for this person. " \
                                'It resets at midnight, or ask an admin to raise it.'
    end

    # Write tools call this after each record they create or change. The rows
    # are saved with the audit row for this call, and are what Undo reverses.
    def record_change(action:, record:, before: {}, after: {})
      pending_changes << { action: action, record_type: record.class.name, record_id: record.id,
                           before: before.deep_stringify_keys, after: after.deep_stringify_keys }
    end

    def pending_changes
      @pending_changes ||= []
    end

    def records_used_today
      McpToolCall.where(user_id: user.id, company_id: company.id, created_at: Time.current.beginning_of_day..)
                 .sum(:result_count)
    end

    # Reads the budget before this call's audit row exists, so calls made in
    # parallel can each overshoot by up to one page (MAX_ROWS). Accepted: the
    # budget is a brake on bulk export, not an exact quota.
    def row_limit(requested)
      remaining = daily_record_limit - records_used_today
      if remaining <= 0
        raise LimitReached, "Daily limit of #{daily_record_limit} records reached for this connection. It resets at midnight."
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
      call = McpToolCall.create!(
        oauth_grant_id: grant&.id, user_id: user.id, company_id: company.id,
        client_name: grant&.oauth_client&.client_name, tool_name: tool_name,
        arguments: self.class.redact(arguments), status: status, result_count: result_count,
        duration_ms: duration_ms, error_message: error_message.to_s.first(500).presence, created_at: Time.current
      )
      # Recorded whatever the call's outcome: a change saved before a later
      # step failed still happened and must still be undoable.
      now = Time.current
      pending_changes.each do |change|
        McpChange.create!(change.merge(mcp_tool_call_id: call.id, oauth_grant_id: grant&.id, user_id: user.id,
                                       company_id: company.id, created_at: now))
      end
      pending_changes.clear
      call
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

    # A company-tier role covers the whole company, records with no location
    # included, exactly as the app treats it. Only location-tier users are
    # narrowed (and see nothing when none of their locations is usable).
    def company_tier_role?
      user.user_role_assignments.active.where(tier: 'company', company_id: company.id).exists?
    end

    def company_admin_assignment?
      return false unless rbac?

      user.user_role_assignments.joins(:role)
          .where(company_id: company.id, roles: { tier: 'company' })
          .where(roles: { key: %w[company_admin admin super_admin] }).exists?
    end
  end
end
