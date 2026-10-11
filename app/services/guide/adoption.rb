# frozen_string_literal: true

module Guide
  # How much each dealership actually uses the product (backlog E75, phase 7),
  # for us: who is drifting, and which paid add-ons nobody opens. Built from
  # guide_events (kept 90 days) and users.last_active_at.
  class Adoption
    WINDOW = 30.days

    def initialize(now: Time.current)
      @now = now
      @module_features = module_features
      # "Nobody opened it in a month" is only true once tracking has run for
      # a month. Before that every add-on looks unused.
      first_event = GuideEvent.minimum(:occurred_at)
      @full_window = first_event.present? && first_event <= @now - WINDOW
    end

    # ids: just these companies (one dealer's own tips), else all active ones.
    def companies(limit: 200, ids: nil)
      events = ids ? GuideEvent.where(company_id: ids) : GuideEvent.all
      recent = events.where(occurred_at: (@now - WINDOW)..@now)
      prior = events.where(occurred_at: (@now - (2 * WINDOW))...(@now - WINDOW))
      active_now = recent.group(:company_id).distinct.count(:user_id)
      active_before = prior.group(:company_id).distinct.count(:user_id)
      features_now = recent.where(kind: 'page').group(:company_id).distinct.count(:feature_key)
      used_keys = recent.where(kind: 'page').distinct.pluck(:company_id, :feature_key).group_by(&:first)
                        .transform_values { |pairs| pairs.map(&:last).to_set }
      last_event = events.group(:company_id).maximum(:occurred_at)
      users_scope = ids ? User.where(company_id: ids) : User.where.not(company_id: nil)
      last_login = users_scope.group(:company_id).maximum(:last_active_at)
      companies = ids ? Company.where(id: ids) : Company.where(status: [nil, 'active'])

      companies.limit(limit).map do |company|
        users = active_now[company.id].to_i
        before = active_before[company.id].to_i
        last_seen = [last_event[company.id], last_login[company.id]].compact.max
        unused = unused_modules(company, used_keys[company.id] || Set.new)
        {
          id: company.id, name: company.name, industry: company.try(:industry),
          active_users_30d: users, active_users_prior_30d: before,
          features_used_30d: features_now[company.id].to_i,
          last_seen_at: last_seen,
          unused_paid_modules: unused,
          drifting: drifting?(users, before, last_seen)
        }
      end.sort_by { |c| [c[:drifting] ? 0 : 1, -c[:active_users_30d]] }
    end

    private

    # Fewer than half the people who used it last month, or nobody for two weeks.
    def drifting?(now_users, before_users, last_seen)
      return true if last_seen.nil? || last_seen < @now - 14.days
      return false if before_users.zero?

      now_users < (before_users / 2.0)
    end

    # Module keys on the plan whose Atlas pages nobody at the company opened.
    def unused_modules(company, used)
      return [] unless @full_window

      enabled = ModuleAccessService.new(company).enabled_modules rescue []
      Array(enabled).filter_map do |key|
        features = @module_features[key]
        next if features.blank? || features.any? { |f| used.include?(f) }

        key
      end
    end

    def module_features
      Guide::Atlas.entries.each_with_object(Hash.new { |h, k| h[k] = [] }) do |e, map|
        Array(e['requires']).each { |r| map[r['moduleKey']] << e['key'] if r['moduleKey'].present? }
      end
    end
  end
end
