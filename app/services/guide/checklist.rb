# frozen_string_literal: true

module Guide
  # Getting started (backlog E75, phase 6), in two parts:
  #
  # Setup: what a dealership needs in place, for whoever can set it up
  # (company admins). Each item is checked against the company's real data,
  # the way Plays::Readiness checks a play, and links to where it is done.
  #
  # Learning path: the parts of the product a person in a given role should
  # know, each ticked off by actually using it (guide_feature_usages), never by
  # clicking "done". Items are Atlas keys, so the app can show where each one
  # is. Only items this person can open are included.
  class Checklist
    PATHS = {
      'sales' => {
        name: 'Sales',
        items: [
          ['page:/crm', 'Work your leads'],
          ['page:/contacts', 'Look up a customer'],
          ['page:/deals', 'Move a deal through your stages'],
          ['page:/quotes', 'Build a quote'],
          ['page:/calendar', 'Check your calendar'],
          ['page:/tasks', 'Keep up with your tasks']
        ]
      },
      'manager' => {
        name: 'Sales manager',
        items: [
          ['page:/dashboard', 'Read the dashboard'],
          ['page:/deals', 'Review the pipeline'],
          ['report:deal-profitability', 'See gross on each deal'],
          ['report:salesperson-gp-pipeline', 'See how each rep is doing'],
          ['page:/workflow-automation', 'Automate follow ups'],
          ['setting:users', 'Manage your team']
        ]
      },
      'office' => {
        name: 'Office and accounting',
        items: [
          ['page:/accounting', 'Open the accounting dashboard'],
          ['page:/accounting/bank-transactions', 'Categorize bank transactions'],
          ['page:/accounting/bills', 'Enter and pay bills'],
          ['report:profit-and-loss', 'Run a Profit & Loss'],
          ['report:balance-sheet', 'Run a Balance Sheet'],
          ['report:ar-aging', 'See who owes you']
        ]
      },
      'service' => {
        name: 'Service',
        items: [
          ['page:/service', 'Work service tickets'],
          ['page:/warranty/claims', 'File warranty claims'],
          ['page:/calendar', 'Schedule visits'],
          ['page:/contacts', 'Look up a customer']
        ]
      }
    }.freeze

    def initialize(user, company)
      @user = user
      @company = company
    end

    def to_h(selected_path: nil)
      visible = Guide::Atlas.new(@user, @company).visible.index_by { |e| e['key'] }
      used = GuideFeatureUsage.where(user_id: @user.id, company_id: @company.id).pluck(:feature_key).to_set
      paths = PATHS.filter_map do |key, path|
        items = path[:items].filter_map do |feature, label|
          next unless visible.key?(feature)

          { feature: feature, label: label, done: used.include?(feature) }
        end
        { key: key, name: path[:name], items: items } if items.size >= 2
      end
      chosen = paths.find { |p| p[:key] == selected_path } || paths.find { |p| p[:key] == default_path } || paths.first

      { setup: setup_visible? ? setup_items : nil, paths: paths, selected_path: chosen&.dig(:key) }
    end

    def default_path
      names = Array(@user.try(:roles)).map { |r| r.try(:name).to_s.downcase } + [@user.role.to_s.downcase]
      return 'office' if names.any? { |n| n.match?(/account|office|bookkeep|finance|controller/) }
      return 'service' if names.any? { |n| n.match?(/service|tech|warranty/) }
      return 'manager' if names.any? { |n| n.match?(/manager|owner|admin|gm/) }

      'sales'
    end

    private

    def setup_visible?
      @user.effective_admin? || @user.try(:company_admin?)
    end

    def modules
      @modules ||= ModuleAccessService.new(@company)
    end

    def setup_items
      [
        item('locations', 'Add your locations', '/locations') { @company.locations.where(active: true, is_deleted: false).exists? },
        item('team', 'Invite your team', '/settings?tab=users') { @company.users.where.not(id: @user.id).exists? },
        item('branding', 'Add your logo', '/settings?tab=branding') { logo? },
        item('pipeline', 'Set your deal stages', '/settings?tab=pipeline') { Setting.get('Company', @company.id, 'pipeline_stages', nil).present? },
        item('email', 'Connect your email', '/account/settings?tab=email') do
          UserEmailConnection.where(company_id: @company.id).active.exists? || @company.company_domains.email_verified.exists?
        end,
        # Posts, comments and Facebook lead ads all need the Page. An expired
        # connection is not done: it needs reconnecting.
        item('facebook', 'Connect your Facebook Page', '/settings?tab=integrations') do
          page = FacebookIntegration.current_for(@company)
          page.present? && !page.token_expired?
        end,
        item('inventory', 'Add your inventory', '/inventory') { @company.vehicles.exists? },
        item('leads', 'Get your first lead in', '/crm') { @company.leads.exists? },
        (item('quickbooks', 'Connect QuickBooks', '/settings?tab=integrations') { QuickbooksConnection.where(company_id: @company.id).any?(&:connected?) } if module?('finance.accounting')),
        (item('website', 'Publish your website', '/company/settings/website') { @company.websites.where(status: 'published').exists? } if module?('marketing.website'))
      ].compact
    end

    def module?(key)
      modules.has_module?(key)
    rescue StandardError
      false
    end

    def logo?
      b = @company.branding_settings || {}
      %w[logo logoUrl logo_url].any? { |k| b[k].present? || b[k.to_sym].present? } || @company.try(:logo).present?
    end

    # One failing lookup marks its item not done rather than breaking the list.
    def item(key, label, route)
      done = begin
        yield ? true : false
      rescue StandardError => e
        Rails.logger.info("[Guide::Checklist] #{key}: #{e.class} #{e.message}")
        false
      end
      { key: key, label: label, route: route, done: done }
    end
  end
end
