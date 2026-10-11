# frozen_string_literal: true

module Guide
  # A few suggestions for one person, picked from how they actually use the
  # product (backlog E75, phase 7). Shown inside the Getting started panel,
  # never as a pop-up, and each can be dismissed for good.
  class Tips
    MAX = 3

    def initialize(user, company)
      @user = user
      @company = company
    end

    def to_a
      dismissed = Array(Setting.get('User', @user.id, 'guide_tips_dismissed', []))
      [next_step, reports_tip, *unused_module_tips].compact.reject { |t| dismissed.include?(t[:key]) }.first(MAX)
    end

    private

    def used
      @used ||= GuideFeatureUsage.where(user_id: @user.id, company_id: @company.id).pluck(:feature_key).to_set
    end

    def visible
      @visible ||= Guide::Atlas.new(@user, @company).visible.index_by { |e| e['key'] }
    end

    def checklist
      @checklist ||= Guide::Checklist.new(@user, @company)
    end

    # The next thing on their learning path.
    def next_step
      prefs = Setting.get('User', @user.id, 'guide_checklist', {}) || {}
      data = checklist.to_h(selected_path: prefs['path'])
      path = data[:paths].find { |p| p[:key] == data[:selected_path] }
      item = path && path[:items].find { |i| !i[:done] }
      return unless item

      { key: "next:#{item[:feature]}", feature: item[:feature], title: "Next: #{item[:label]}",
        text: "It is the next step on your #{path[:name].downcase} path." }
    end

    # Busy in the product but never opened a report.
    def reports_tip
      return if used.size < 5 || used.any? { |k| k.start_with?('report:') }

      key = %w[report:salesperson-gp-pipeline report:deal-profitability report:profit-and-loss report:inventory-stock-list]
            .find { |k| visible.key?(k) }
      return unless key

      { key: 'reports', feature: key, title: "Try the #{visible[key]['title']} report",
        text: 'You use a lot of the product but have not opened a report yet. Your numbers are a click away.' }
    end

    # Add-ons the company pays for that nobody has opened in a month. For the
    # people who decide what the dealership uses.
    def unused_module_tips
      return [] unless @user.effective_admin?

      company = Guide::Adoption.new.companies(ids: [@company.id]).first
      Array(company&.dig(:unused_paid_modules)).first(2).filter_map do |module_key|
        entry = visible.values.find { |e| Array(e['requires']).any? { |r| r['moduleKey'] == module_key } }
        next unless entry

        name = PlatformModule::MODULES.dig(module_key, :name) || entry['title']
        { key: "module:#{module_key}", feature: entry['key'], title: "#{name} is on your plan",
          text: "Nobody at #{@company.name} has opened it in the last month. Take a look at what it does." }
      end
    end
  end
end
