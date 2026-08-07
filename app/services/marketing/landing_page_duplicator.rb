# frozen_string_literal: true

module Marketing
  # Copies a landing page.
  #
  # Follows CampaignsController#duplicate rather than SiteEditor's frontend page
  # clone. The frontend clone is fine for a static marketing page: it deep-copies
  # blocks with fresh ids and moves on. A landing page owns state that must not
  # travel — visits, engagement, a bound intake form, a campaign link, and a
  # canonical URL. Copying canonical_path alone would point every clone's SEO at
  # the original.
  #
  # What carries: blocks (with fresh block ids), theme, media references, the
  # source Content Profile, the layout, and the SHAPE of the intake form.
  # What resets: path, publish state, campaign link, canonical, robots, and
  # anything derived from traffic the original received.
  class LandingPageDuplicator
    class DuplicationError < StandardError; end

    # @param page [WebsitePage] the landing page to copy
    # @param user [User] who is doing it
    # @param title [String, nil] override for the copy's title
    # @param location [Location, nil] re-point the copy at another location
    # @param campaign_id [Integer, nil] attach the copy to a campaign
    # @param share_form [Boolean] reuse the original's intake form instead of
    #   cloning it. Off by default — see #resolve_intake_form.
    def initialize(page, user:, title: nil, location: nil, campaign_id: nil, share_form: false)
      @page = page
      @user = user
      @title = title
      @location = location
      @campaign_id = campaign_id
      @share_form = share_form
    end

    def call
      raise DuplicationError, 'Only landing pages can be duplicated this way.' unless @page.landing_page?

      ActiveRecord::Base.transaction do
        form = resolve_intake_form
        copy = build_copy(form)
        copy.save!
        copy
      end
    end

    private

    def build_copy(form)
      @page.website.website_pages.new(
        title: copy_title,
        path: unique_path,
        page_kind: 'landing',
        order: next_order,

        # --- carried ---
        blocks: cloned_blocks(form),
        style: @page.style,
        seo_title: @page.seo_title,
        seo_description: @page.seo_description,
        og_image_url: @page.og_image_url,
        site_content_profile_id: @page.site_content_profile_id,
        layout_id: @page.layout_id,
        intake_form_id: form&.id,

        # --- reset ---
        #
        # canonical_path: inheriting it tells search engines the copy is the
        # original, which is exactly backwards.
        canonical_path: nil,
        # A copy starts as a draft. Publishing is a decision, and cloning to
        # twelve locations must not put twelve pages live at once.
        is_visible: false,
        published_at: nil,
        # Standalone unless the caller says otherwise. A copy of a campaign page
        # is not part of that campaign.
        campaign_id: @campaign_id,
        # robots is re-applied by WebsitePage's landing defaults on create.
        robots: nil,
        show_in_nav: false,
        show_in_footer: false
      )
    end

    # "(Copy)" prefix matches CampaignsController#duplicate, so the two read the
    # same way in a list.
    def copy_title
      @title.presence || "(Copy) #{@page.title}"
    end

    # WebsitePage validates path uniqueness per website, and every clone of a
    # popular offer competes for the same slug.
    def unique_path
      base = @page.path.to_s.sub(%r{\A/}, '').presence || 'landing'
      base = base.sub(/-copy(-\d+)?\z/, '')
      candidate = "/#{base}-copy"
      suffix = 2

      while @page.website.website_pages.exists?(path: candidate)
        candidate = "/#{base}-copy-#{suffix}"
        suffix += 1
      end
      candidate
    end

    def next_order
      (@page.website.website_pages.maximum(:order) || 0) + 1
    end

    # Fresh block ids. Two pages sharing block ids makes the editor's
    # select-and-edit ambiguous, and SiteEditor already de-duplicates ids
    # defensively on load — a sign this has bitten before.
    def cloned_blocks(form)
      Array(@page.blocks).map.with_index do |block, index|
        copy = deep_dup(block)
        copy['id'] = "block_#{SecureRandom.hex(6)}_#{index}"
        rebind_form(copy, form)
        rebind_location(copy)
        copy
      end
    end

    def deep_dup(value)
      case value
      when Hash  then value.transform_values { |v| deep_dup(v) }
      when Array then value.map { |v| deep_dup(v) }
      else value
      end
    end

    # The contact block is where SiteRenderer reads the form id.
    def rebind_form(block, form)
      return unless block['type'].to_s == 'contact'

      content = block['content'].is_a?(Hash) ? block['content'] : {}
      content['intakeFormId'] = form&.id
      block['content'] = content
    end

    # Inventory blocks are scoped to a location. A clone pointed at another
    # rooftop that still lists the original's stock is worse than one listing
    # nothing, because nothing about it looks wrong.
    def rebind_location(block)
      return if @location.nil?
      return unless %w[inventory inventorySearch inventory_search].include?(block['type'].to_s)

      content = block['content'].is_a?(Hash) ? block['content'] : {}
      content['locationId'] = @location.id
      block['content'] = content
    end

    # Clone the form by default.
    #
    # Sharing one form across copies co-mingles submissions, which makes
    # per-page attribution impossible — and per-page attribution is the entire
    # point of the tracking these pages carry. Sharing stays available for the
    # rare case of one deliberately pooled inbox.
    def resolve_intake_form
      source = @page.intake_form
      return nil if source.nil?
      return source if @share_form

      clone = source.dup
      clone.name = "#{source.name} (#{@location&.name || copy_title})".truncate(120)
      # public_id is unique and is the form's public URL; IntakeForm regenerates
      # it before_create, but only when blank.
      clone.public_id = nil
      clone.submission_count = 0
      clone.location_id = @location&.id || source.location_id
      clone.notified_user_id = notified_user_id_for(source)
      clone.save!
      clone
    end

    # A form that notifies someone at another rooftop sends every lead to the
    # wrong person. Fall back to the original only when the target location has
    # nobody obvious.
    def notified_user_id_for(source)
      return source.notified_user_id if @location.nil?

      @location.users.active.order(:id).first&.id || source.notified_user_id
    rescue StandardError
      source.notified_user_id
    end
  end
end
