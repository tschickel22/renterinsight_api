# frozen_string_literal: true

module Guide
  # The server's copy of the Atlas: the latest build's map of every page,
  # report, setting and action, as recorded by the release watcher. Filtered to
  # what a person can open with the same rules the frontend's useAtlas uses
  # (the frontend checks again before it offers to take anyone anywhere).
  class Atlas
    def self.entries
      snapshot = Knowledge::Snapshot.where(source: Guide::ReleaseWatcher::SOURCE).order(snapshot_at: :desc).first
      Array(snapshot&.atlas&.dig('entries'))
    end

    # Plain word match over titles, synonyms, where and description.
    def self.search(entries, query, limit: 6)
      words = query.to_s.downcase.scan(/[a-z0-9&]+/).reject { |w| w.length < 3 }
      return [] if words.empty?

      entries.map do |e|
        title = e['title'].to_s.downcase
        other = [e['synonyms'], e['breadcrumb'], e['description']].flatten.compact.join(' ').downcase
        [e, words.sum { |w| (title.include?(w) ? 3 : 0) + (other.include?(w) ? 1 : 0) }]
      end.select { |_, s| s.positive? }.sort_by { |_, s| -s }.first(limit).map(&:first)
    end

    def initialize(user, company)
      @user = user
      @company = company
      @modules = ModuleAccessService.new(company)
      @permissions = PermissionService.new(user)
    end

    def visible(entries = self.class.entries)
      entries.select { |e| Array(e['requires']).all? { |r| meets?(r) } }
    end

    private

    def platform_admin?
      @user.platform_admin? || @user.super_admin?
    end

    def admin?
      @user.effective_admin?
    end

    def rbac?
      @user.uses_rbac?
    end

    def can?(resource, action = 'read')
      !rbac? || @permissions.can?(resource, action)
    end

    def module?(key)
      @modules.has_module?(key)
    end

    def meets?(r)
      return true if platform_admin? && !r['settingsAccess'] && !r['integrationsSub']
      return can?(r['reportResource']) if r['reportResource']
      return settings?(r['settingsAccess']) if r['settingsAccess']
      return integrations?(r['integrationsSub']) if r['integrationsSub']
      return false if r['adminOnly']
      return false if r['moduleKey'].present? && !module?(r['moduleKey'])
      return can?(r['resource'], r['action'] || 'read') if r['resource'].present?
      return Array(r['anyResource']).any? { |res| can?(res) } if Array(r['anyResource']).any?

      true
    end

    def settings?(access)
      case access
      when 'all' then true
      when 'manage' then admin?
      when 'platformAdmin' then platform_admin?
      when 'truebuild' then platform_admin? || (admin? && module?('sales.configurator'))
      when 'projectTemplates' then (admin? || can?('project_templates')) && module?('management.projects')
      else false
      end
    end

    def integrations?(sub)
      case sub
      when 'api-keys' then platform_admin? || (admin? && module?('admin.api_keys'))
      when 'webhooks' then platform_admin? || (admin? && module?('admin.webhooks'))
      when 'ai-apps' then platform_admin? || module?('admin.ai_connector')
      else platform_admin?
      end
    end
  end
end
