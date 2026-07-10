module Messaging
  class InventoryBlockResolver
    AVAILABLE_STATUSES = %w[available available_to_order].freeze
    ALLOWED_STATUSES   = %w[available available_to_order pending reserved].freeze
    DEFAULT_MAX_UNITS  = 6

    def initialize(config:, recipient:, company:, base_url: nil)
      @config = config.is_a?(Hash) ? config : {}
      @recipient = recipient
      @company = company
      @base_url = base_url
    end

    def resolve
      mode = @config['mode'] || @config[:mode] || 'category_based'
      base = company_vehicles_scope

      filtered = case mode.to_s
                 when 'segment_based'  then apply_segment(base)
                 when 'category_based' then apply_category(base)
                 when 'manual_pick'    then apply_manual(base)
                 else base
                 end

      sorted = apply_sort(filtered)
      max = (@config['max_units'] || @config[:max_units] || DEFAULT_MAX_UNITS).to_i
      max = DEFAULT_MAX_UNITS if max <= 0
      units = sorted.limit(max).map { |v| unit_hash(v) }

      if units.empty?
        case (@config['fallback'] || @config[:fallback] || 'skip_block').to_s
        when 'show_cta'    then { units: [], fallback_action: :show_cta }
        when 'abort_send'  then { units: [], fallback_action: :abort_send }
        else                    { units: [], fallback_action: :skip_block }
        end
      else
        { units: units, fallback_action: :rendered }
      end
    end

    private

    def company_vehicles_scope
      base = @company.vehicles.where(status: allowed_statuses)
      base = base.where(is_deleted: [false, nil]) if Vehicle.column_names.include?('is_deleted')
      base = require_images_scope(base) if require_images?
      base
    end

    # Admin-selected status set from config.filters.statuses; ignores any
    # entries outside ALLOWED_STATUSES so a bad payload can't leak
    # sold/pending listings into a marketing send. Falls back to today's
    # default (available + available_to_order) when unset.
    def allowed_statuses
      f = @config['filters'] || @config[:filters] || {}
      picked = Array(f['statuses'] || f[:statuses]).map(&:to_s).select { |s| ALLOWED_STATUSES.include?(s) }
      picked.presence || AVAILABLE_STATUSES
    end

    def require_images?
      f = @config['filters'] || @config[:filters] || {}
      ActiveModel::Type::Boolean.new.cast(f['require_images'] || f[:require_images] || false)
    end

    # Postgres jsonb: non-empty array literal is not equal to '[]'. Also
    # rules out NULL. Doesn't validate individual entries — that's the
    # unit_hash's problem — this is a fast pre-filter.
    def require_images_scope(rel)
      rel.where("images IS NOT NULL AND images::text NOT IN ('[]', '')")
    end

    def apply_segment(base)
      filters = @config['segment_preferences'] || @config[:segment_preferences] || {}
      r = base
      if filters['use_recipient_budget'] && @recipient.respond_to?(:custom_field_values)
        budget = @recipient.custom_field_values&.dig('budget_max')
        r = r.where('sale_price <= ?', budget.to_f) if budget.present?
      end
      if filters['use_recipient_preferences'] && @recipient.respond_to?(:custom_field_values)
        bedrooms_min = @recipient.custom_field_values&.dig('bedrooms_min')
        r = r.where('bedrooms >= ?', bedrooms_min.to_i) if bedrooms_min.present?
      end
      apply_static_filters(r)
    end

    def apply_category(base)
      apply_static_filters(base)
    end

    def apply_manual(base)
      ids = Array(@config['manual_vehicle_ids'] || @config[:manual_vehicle_ids]).map(&:to_i).reject(&:zero?)
      return base.none if ids.empty?
      base.where(id: ids)
    end

    def apply_static_filters(rel)
      f = @config['filters'] || @config[:filters] || {}
      rel = rel.where(listing_type: f['listing_type']) if f['listing_type'].present?
      rel = rel.where('bedrooms >= ?', f['bedrooms_min'].to_i) if f['bedrooms_min'].present?
      rel = rel.where('sale_price <= ?', f['price_max'].to_f) if f['price_max'].present?
      # Orderable inventory has no location_id — a naive location filter
      # silently drops it. Preserve orderable units when the caller allows
      # them via the status set, so a location-scoped weekly digest still
      # shows "build to order" homes alongside physical lot units.
      if f['location_ids'].is_a?(Array) && f['location_ids'].any? && Vehicle.column_names.include?('location_id')
        if allowed_statuses.include?('available_to_order')
          rel = rel.where('location_id IN (?) OR status = ?', f['location_ids'], 'available_to_order')
        else
          rel = rel.where(location_id: f['location_ids'])
        end
      end
      rel = rel.where(condition: f['condition']) if f['condition'].present?
      rel
    end

    def apply_sort(rel)
      case (@config['sort'] || @config[:sort]).to_s
      when 'price_low'  then rel.order(:sale_price)
      when 'price_high' then rel.order(sale_price: :desc)
      when 'newest'     then rel.order(created_at: :desc)
      when 'best_match' then rel.order(:sale_price)
      else                   rel.order(created_at: :desc)
      end
    end

    def unit_hash(v)
      raw = v.images
      images = case raw
               when Array then raw
               when String then (JSON.parse(raw) rescue [])
               else []
               end
      first_image = images.first
      img_url = case first_image
                when Hash then (first_image['url'] || first_image[:url])
                when String then first_image
                else nil
                end
      {
        id: v.id,
        year: v.year,
        make: v.make,
        model: v.model,
        sale_price: v.sale_price,
        bedrooms: v.bedrooms,
        bathrooms: v.bathrooms,
        image_url: img_url,
        url: public_url(v)
      }
    end

    # Per-vehicle detail link. Must point at the FE (public_inventory_token
    # gates access; the FE route is /public/inventory/:vehicleId with the
    # token as a query param). The previous shape used @base_url (the API
    # host) with a path-style token — that's not a route the FE ships and
    # produced 404s when recipients clicked "View details" in the email.
    # Mirrors InventoryEmailBlockBuilder#build_public_inventory_url so the
    # nurture and campaign flows produce identical links.
    def public_url(v)
      token = @company.try(:public_inventory_token)
      return '#' if token.blank?
      "#{frontend_base_url}/public/inventory/#{v.id}?token=#{token}&company_id=#{@company.id}"
    end

    # DMS frontend URL — same lookup order the nurture builder uses.
    # company#dms_frontend_url wins for tenants with a custom domain;
    # DMS_FRONTEND_URL / FRONTEND_URL cover the shared staging + prod
    # deploys; staging fallback keeps preview working without env config.
    def frontend_base_url
      @company.try(:dms_frontend_url).presence ||
        ENV['DMS_FRONTEND_URL'].presence ||
        ENV['FRONTEND_URL'].presence ||
        'https://staging-dms.renterinsight.com'
    end
  end
end
