# frozen_string_literal: true

module SiteProfiles
  # Finds inventory to show in a showcase when the viewer has none of their own.
  #
  # Needed in two places, both of which would otherwise render the inventory
  # block's "not configured" placeholder — the most prominent thing on the page,
  # blank, in front of a customer:
  #   * a prospect demo account, which has no inventory at all
  #   * an existing customer being shown how websites work, who may not have
  #     switched public inventory on yet
  #
  # Resolution order, most-specific first. No ENV var: an admin who wants to
  # pin a particular demo lot sets it in Platform Settings, and otherwise it
  # finds one on its own so this keeps working without configuration.
  class DemoInventoryResolver
    CACHE_KEY = 'site_profiles/demo_inventory_company'
    CACHE_TTL = 10.minutes

    class << self
      # @return [Hash, nil] { 'token', 'company_id', 'enabled', 'is_sample' }
      def config_for(company, allow_fallback: true)
        own = usable_config(company)
        return own if own
        return nil unless allow_fallback

        demo = demo_company
        return nil if demo.nil? || demo.id == company&.id

        usable_config(demo)&.merge('is_sample' => true)
      end

      def demo_company
        id = Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { discover_company_id }
        id && Company.find_by(id: id)
      end

      def clear_cache!
        Rails.cache.delete(CACHE_KEY)
      end

      # A company can serve demo inventory only if the public embed would
      # actually return something. Checking the token alone is not enough —
      # an enabled-but-empty lot still renders an empty grid.
      def usable_config(company)
        return nil if company.nil?
        return nil unless company.try(:public_inventory_enabled)

        token = company.try(:public_inventory_token)
        return nil if token.blank?

        { 'token' => token, 'company_id' => company.id, 'enabled' => true }
      end

      private

      def discover_company_id
        explicit_id || internal_tenant_id || best_stocked_id
      end

      # 1. Explicitly pinned in Platform Settings -> general.
      def explicit_id
        id = PlatformSetting.general[:demoInventoryCompanyId].presence
        id&.to_i
      rescue StandardError
        nil
      end

      # 2. Our own internal tenant, if someone seeded a demo lot onto it.
      def internal_tenant_id
        candidates(Company.where(industry: 'saas')).first
      end

      # 3. Otherwise whichever company has the most published inventory —
      #    a real, full-looking lot beats an enabled-but-bare one.
      def best_stocked_id
        candidates(Company.all).first
      end

      def candidates(scope)
        scope
          .where(public_inventory_enabled: true)
          .where.not(public_inventory_token: [nil, ''])
          .joins(:vehicles)
          .where(vehicles: { status: 'available' })
          .group('companies.id')
          .order(Arel.sql('COUNT(vehicles.id) DESC'))
          .limit(1)
          .pluck('companies.id')
      rescue StandardError => e
        Rails.logger.warn("[DemoInventoryResolver] candidate lookup failed: #{e.message}")
        []
      end
    end
  end
end
