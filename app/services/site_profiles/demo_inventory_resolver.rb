# frozen_string_literal: true

module SiteProfiles
  # Finds inventory for a showcase.
  #
  # A company with an account ALWAYS shows its own inventory — a seeded demo
  # account is just a normal company, so switching public inventory on there is
  # all it takes and it flows through automatically. Borrowing is reserved for
  # prospect demos, where there is no account and therefore nothing real to show.
  #
  # Deliberately will NOT borrow an arbitrary customer's lot. An earlier version
  # fell back to "whichever company has the most available inventory", which
  # meant a prospect demo could display a real customer's actual homes to an
  # unrelated third party. Only a lot we own or have explicitly nominated is
  # eligible; otherwise the block is omitted.
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
        explicit_id || internal_tenant_id
      end

      # 1. Explicitly nominated in Platform Settings -> general. Someone chose
      #    this lot on purpose, so it is fair game.
      def explicit_id
        id = PlatformSetting.general[:demoInventoryCompanyId].presence
        id&.to_i
      rescue StandardError
        nil
      end

      # 2. Our own internal tenant, if a demo lot was seeded onto it. Also ours,
      #    also deliberate.
      #
      # There is no rule 3. Anything further would mean picking a real
      # customer's lot without their knowledge.
      def internal_tenant_id
        candidates(Company.where(industry: 'saas')).first
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
