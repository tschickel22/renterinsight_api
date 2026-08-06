# frozen_string_literal: true

module SiteProfiles
  # Finds inventory for a showcase.
  #
  # A company with an account ALWAYS shows its own inventory — a seeded demo
  # account is just a normal company, so switching public inventory on there is
  # all it takes and it flows through automatically. Borrowing is reserved for
  # prospect demos, where there is no account and therefore nothing real to show.
  #
  # Borrows only from a lot we own or have explicitly nominated. The stock
  # itself is public — that is what the public inventory embed is for — but
  # showing an arbitrary customer's homes on someone else's demo implies the
  # prospect would be getting those homes, which they would not. One nominated
  # demo lot keeps the pitch honest and predictable.
  class DemoInventoryResolver
    CACHE_KEY = 'site_profiles/demo_inventory_company'
    CACHE_TTL = 10.minutes

    class << self
      # For a company that has an account: its own lot, or nothing.
      # @return [Hash, nil] { 'token', 'company_id', 'enabled' }
      def config_for(company, allow_fallback: true)
        own = usable_config(company)
        return own if own
        return nil unless allow_fallback

        demo = demo_company
        return nil if demo.nil? || demo.id == company&.id

        usable_config(demo)&.merge('is_sample' => true)
      end

      # For a demo profile, where the lot is CHOSEN rather than inherited.
      #
      # Deliberately ignores profile.company: that is only the tenant the admin
      # happened to be switched to when creating the demo, so inheriting it
      # would put an unrelated dealer's homes in front of the prospect.
      #
      #   explicit choice -> that lot, flagged sample unless it is the subject's
      #   no choice       -> the nominated demo lot
      #   neither         -> nil, and the block is omitted
      def config_for_profile(profile)
        chosen = profile.try(:inventory_company)
        if chosen
          config = usable_config(chosen)
          return nil if config.nil?

          # Their own homes only when the demo is actually about them.
          return config if chosen.id == profile.company_id

          return config.merge('is_sample' => true)
        end

        demo = demo_company
        return nil if demo.nil?

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
      #
      # 'card' carries the lot owner's own listing presentation (layout, per
      # page, whether pricing shows). It travels with the token because it
      # describes THAT lot: borrowing a demo lot's homes means borrowing the way
      # that lot displays them, and a dealer previewing their own inventory
      # should see the card they configured rather than a template default.
      def usable_config(company)
        return nil if company.nil?
        return nil unless company.try(:public_inventory_enabled)

        token = company.try(:public_inventory_token)
        return nil if token.blank?

        {
          'token' => token,
          'company_id' => company.id,
          'enabled' => true,
          'card' => Websites::InventoryCardSettings.for(company)
        }
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
      # There is no rule 3. Auto-picking "whichever company has the most
      # inventory" would put an unrelated dealer's stock in a sales pitch
      # without anyone deciding to.
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
