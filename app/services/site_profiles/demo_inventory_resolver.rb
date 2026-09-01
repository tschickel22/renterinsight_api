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

    # Read from outside this class by SiteContentProfilesController#inventory_lots,
    # so they have to be on the class and not on its singleton. See the notes
    # further down for what each one is for.
    ENABLED_VALUES = %w[true t 1].freeze
    SELLABLE_STATUSES = %w[available available_to_order].freeze

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

      # Which lot a demo shows.
      #
      #   explicit choice     -> that lot, flagged sample unless it is the subject's
      #   tenant with stock   -> its own homes, not a sample
      #   otherwise           -> the nominated demo lot, flagged sample
      #   nothing usable      -> nil, and the block is omitted
      def config_for_profile(profile)
        chosen = profile.try(:inventory_company)
        if chosen
          config = usable_config(chosen)
          return nil if config.nil?

          # Their own homes only when the demo is actually about them.
          return config if chosen.id == profile.company_id

          return config.merge('is_sample' => true)
        end

        # The tenant the demo was built under, when it has homes to show.
        #
        # This used to skip straight to the nominated demo lot, on the reasoning
        # that profile.company is merely whoever the admin happened to be
        # switched to. In practice that is backwards: an admin building a demo
        # while switched into a dealer is building it FOR that dealer, and
        # showing thirty catalog homes from our own tenant instead of their 132
        # is the wrong answer every time. Reported from staging, where a demo
        # created under Summit Park rendered the internal lot.
        #
        # Not flagged as a sample, because it is not one — these are the homes
        # the site would actually carry, which is also what makes the
        # manufacturer logos come out right.
        own = usable_config(profile.try(:company))
        # Stock checked separately, because usable_config does not.
        #
        # A new company is created with public inventory already enabled and a
        # token already issued, so usable_config says yes to a lot with zero
        # homes — preferring the tenant without this check would swap a
        # borrowed lot that has homes for an empty grid, which is worse than
        # the problem being fixed.
        return own if own && stocked?(profile.try(:company))

        demo = demo_company
        return nil if demo.nil?

        usable_config(demo)&.merge('is_sample' => true)
      end

      # Does this lot actually have anything a visitor could look at?
      def stocked?(company)
        return false if company.nil?

        company.vehicles
               .where(status: SELLABLE_STATUSES, is_deleted: [false, nil])
               .exists?
      rescue StandardError => e
        Rails.logger.warn("[DemoInventoryResolver] stock check failed for #{company&.id}: #{e.message}")
        false
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

      # public_inventory_enabled is a store_accessor on the
      # public_inventory_settings JSONB, NOT a column. `.where(public_inventory_enabled: true)`
      # therefore raised PG::UndefinedColumn on every call — rescued, logged,
      # and returning [], so rule 2 below silently never fired and only an
      # explicitly nominated lot ever resolved.
      #
      # Worse than a dead code path: the failed statement aborts whatever
      # transaction the caller is in, so any code that resolved a demo lot mid
      # transaction took the whole transaction down with it. Rescuing the Ruby
      # exception does not un-abort a PostgreSQL transaction.
      #
      # Compared as text because the JSONB value may have been written as a
      # boolean or as a string depending on which settings screen wrote it.
      #
      # Lives on the class, NOT inside `class << self`. Defined in there it
      # belongs to the singleton class, so the constant is reachable from these
      # methods but NOT as DemoInventoryResolver::ENABLED_VALUES , which is how
      # SiteContentProfilesController#inventory_lots reads it. That endpoint
      # raised NameError and 500d on every call, so the "which lot should this
      # demo show" picker returned nothing and no demo could be bound to a lot.
      # Declared at the top of the class instead.

      # What counts as a lot worth showing.
      #
      # This used to be 'available' alone, which meant the demo lot could never
      # be found. Our own seeded lot is catalog-fed from Clayton, Champion and
      # TRU, and catalog stock is available_to_order, not available: measured on
      # staging, all 31 of the internal tenant's vehicles. So the query looked
      # for the one status the demo lot does not use, found nothing, and
      # config_for_profile returned nil — which renders a demo site with an
      # unbound inventory block and no homes in it.
      #
      # The rest of the stack already knew this. The public embed serves
      # whatever a company's public_statuses allows (both, everywhere measured),
      # and projectProfile widens a sample lot to both explicitly. This was the
      # last place still assuming a dealer-style lot.
      # Also declared at the top of the class, and for the same reason.

      def candidates(scope)
        scope
          .where("companies.public_inventory_settings ->> 'public_inventory_enabled' IN (?)", ENABLED_VALUES)
          .where.not(public_inventory_token: [nil, ''])
          .joins(:vehicles)
          .where(vehicles: { status: SELLABLE_STATUSES, is_deleted: [false, nil] })
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
