# frozen_string_literal: true

module Outreach
  # Reads a retailer's own website before the first message (backlog E105), so
  # the opener can name one real thing about their business instead of a
  # generic hello, and so the rep has a short summary on the lead later.
  #
  # Reuses the demo scanner's parts (fetcher, URL guard, digests, contact and
  # vendor detection, the SEO audit) on a handful of pages, not a full crawl.
  # The site comes from the lead's website field, or from a business email
  # domain when the site's name or phone matches the lead; free mail never.
  #
  # Facebook and other social pages are recorded as links only. Reading other
  # businesses' Facebook pages needs a Meta permission we do not have, and
  # scraping them is against Meta's terms.
  class SiteResearch
    FREE_MAIL = %w[
      gmail.com googlemail.com yahoo.com ymail.com rocketmail.com hotmail.com live.com msn.com outlook.com aol.com icloud.com me.com
      mac.com comcast.net att.net sbcglobal.net bellsouth.net charter.net verizon.net cox.net earthlink.net frontier.com
      windstream.net centurylink.net embarqmail.com protonmail.com proton.me gmx.com mail.com zoho.com q.com suddenlink.net
      optonline.net juno.com netzero.net tds.net mchsi.com
    ].freeze
    GENERIC_WORDS = %w[
      the and of inc llc co company homes home mobile manufactured modular housing sales center centers retail retailer
      group corp corporation ltd dealer dealership mh realty properties of usa america american
    ].freeze
    PAGE_ROLES = %w[inventory about contact].freeze
    MAX_PAGES = 4
    REUSE_FOR = 60.days

    TOOL = {
      name: 'site_findings',
      description: 'What this retailer\'s website shows, from the page text given only.',
      input_schema: {
        type: 'object',
        properties: {
          summary: { type: 'string', description: 'Two or three plain sentences: what they sell, where, anything notable. Facts from the text only.' },
          brands: { type: 'array', items: { type: 'string' }, description: 'Home builders or brands they carry, as named on the site.' },
          homes_listed: { type: 'integer', description: 'Number of homes shown for sale, only if the text makes it clear. Omit otherwise.' },
          locations: { type: 'array', items: { type: 'string' }, description: 'Sales lot cities and states named on the site.' },
          opener_fact: { type: 'string', description: 'One specific, checkable, flattering or neutral fact a salesperson could mention, under 20 words. Empty if none.' },
          talking_points: { type: 'array', items: { type: 'string' }, description: 'Up to three ways the PRODUCT FACTS could help this business, each tied to something on their site.' }
        },
        required: %w[summary brands locations opener_fact talking_points]
      }
    }.freeze

    def self.for(target)
      new(target).call
    end

    def initialize(target)
      @target = target
      @lead = target.lead
      @company = target.company
    end

    # Stores the result on the target and notes it on the lead. Never raises:
    # a site we cannot read just means the ordinary opener.
    def call
      return @target.site_research if @target.site_research.present?

      research = recent_research || fresh_research
      @target.update!(site_research: research)
      note!(research) if research['status'] == 'found' && research['noted_at'].blank?
      research
    rescue StandardError => e
      Rails.logger.warn("[Outreach::SiteResearch] target #{@target.id}: #{e.class}: #{e.message}")
      @target.update_columns(site_research: { 'status' => 'error', 'checked_at' => Time.current.iso8601 })
      @target.site_research
    end

    def candidate_url
      website = @lead.custom_field_values.to_h['website'].to_s.strip
      return [normalize(website), :website] if website.present?

      domain = @lead.email.to_s.split('@').last.to_s.downcase.strip
      return [nil, nil] if domain.blank? || FREE_MAIL.include?(domain) || !domain.include?('.')

      ["https://#{domain}", :email]
    end

    private

    # Another wave read this lead's site recently: reuse it, no second fetch or note.
    def recent_research
      previous = OutreachTarget.where(company_id: @company.id, lead_id: @lead.id).where.not(id: @target.id)
                               .where("site_research->>'status' = 'found'").order(updated_at: :desc).first
      return unless previous && Time.zone.parse(previous.site_research['checked_at'].to_s) > REUSE_FOR.ago

      previous.site_research.merge('noted_at' => previous.site_research['noted_at'] || Time.current.iso8601)
    rescue ArgumentError, TypeError
      nil
    end

    def fresh_research
      url, from = candidate_url
      return outcome('no_site') unless url
      return outcome('blocked', url: url) unless SiteProfiles::UrlGuard.safe?(url)

      fetcher = SiteProfiles::Fetcher.new
      pages = fetch_pages(fetcher, url)
      return outcome('unreachable', url: url) if pages.empty?

      digests = pages.values.map { |response| SiteProfiles::PageDigest.new(response).call }
      text = page_text(digests)
      return outcome('mismatch', url: url) if from == :email && !matches_lead?(text, digests)

      contact = SiteProfiles::ContactExtractor.new(digests, pages_html: pages.transform_values(&:body)).call
      seo = SiteProfiles::SeoAudit.new(source_url: url, pages_html: pages.transform_values(&:body), fetcher: fetcher).call
      vendors = SiteProfiles::VendorDetector.new(digests, source_host: URI(url).host).call
      findings = ai_findings(text, seo)

      outcome('found', url: url, from: from.to_s).merge(
        'summary' => findings['summary'].to_s.truncate(500),
        'brands' => Array(findings['brands']).map(&:to_s).first(8),
        'homes_listed' => findings['homes_listed'].presence,
        'locations' => Array(findings['locations']).map(&:to_s).first(6),
        'opener_fact' => findings['opener_fact'].to_s.truncate(160).presence,
        'talking_points' => Array(findings['talking_points']).map(&:to_s).first(3),
        'social' => contact['social'].to_h.slice('facebook', 'instagram', 'youtube'),
        'site_platform' => vendor_names(vendors),
        'seo_score' => seo['score'],
        'seo_gaps' => Array(seo['checks']).reject { |c| c['status'] == 'pass' || c['category'] == 'tracking' }.first(3).map { |c| c['headline'] },
        'pages_read' => pages.size
      )
    ensure
      fetcher&.close
    end

    def outcome(status, url: nil, from: nil)
      { 'status' => status, 'url' => url, 'from' => from, 'checked_at' => Time.current.iso8601 }.compact
    end

    def fetch_pages(fetcher, url)
      home = fetcher.get(url, allow_archive: false)
      return {} unless home&.html? && home.status.to_i.between?(200, 299)

      pages = { home.url => home }
      digest = SiteProfiles::PageDigest.new(home).call
      links = SiteProfiles::LinkInventory.new([digest], base_url: home.url).call['internal']
      PAGE_ROLES.each do |role|
        break if pages.size >= MAX_PAGES

        entry = links.find { |link| link['page_role'] == role }
        next unless entry

        page = fetcher.get(URI.join(home.url, entry['path']).to_s, allow_archive: false, allow_render: false)
        pages[page.url] = page if page&.html? && page.status.to_i.between?(200, 299)
      rescue StandardError => e
        Rails.logger.info("[Outreach::SiteResearch] skipped #{role} page: #{e.class}")
      end
      pages
    end

    def page_text(digests)
      digests.map do |d|
        headings = Array(d.headings).map { |h| h.is_a?(Hash) ? (h[:text] || h['text']) : h }
        [d.url, d.title, d.meta_description, *headings, *Array(d.paragraphs)].compact_blank.join("\n").truncate(6000)
      end.join("\n\n---\n\n")
    end

    # A business email domain can belong to a parent company or a web host, so
    # the site must name the lead's business or carry its phone number.
    def matches_lead?(text, _digests)
      haystack = text.downcase
      digits = @lead.phone.to_s.gsub(/\D/, '').last(10)
      return true if digits.length == 10 && haystack.gsub(/\D/, '').include?(digits)

      words = @lead.company_name.to_s.downcase.scan(/[a-z0-9']+/) - GENERIC_WORDS
      words.reject! { |w| w.length < 3 }
      words.any? && words.all? { |w| haystack.include?(w) }
    end

    def vendor_names(vendors)
      Array(vendors).map { |v| v.respond_to?(:vendor) ? v.vendor : v['vendor'] }.compact.uniq.first(4)
    end

    def ai_findings(text, seo)
      settings = Settings.for(@company)
      AiClient.call(
        company: @company, feature: 'site_research', tool: TOOL, max_tokens: 900,
        system: "You read a manufactured home retailer's website for #{@company.name}, which sells software to retailers. " \
                'Report only what the page text says. Never guess a number, brand or place that is not in the text. ' \
                'Do not use dashes as punctuation.',
        user: "PRODUCT FACTS (what #{@company.name} offers)\n#{settings['product_facts'].to_s.truncate(2500)}\n\n" \
              "SEARCH CHECKUP: score #{seo['score'] || 'unknown'} of 100. " \
              "Gaps: #{Array(seo['checks']).reject { |c| c['status'] == 'pass' }.first(3).map { |c| c['headline'] }.join('; ').presence || 'none'}\n\n" \
              "WEBSITE TEXT\n#{text}"
      )
    rescue StandardError => e
      Rails.logger.warn("[Outreach::SiteResearch] AI summary failed: #{e.class}: #{e.message}")
      {}
    end

    # A short summary on the lead, for whoever works it later. A Note, so it
    # never counts as recent activity.
    def note!(research)
      lines = ["Website research #{Date.current.strftime('%b %-d, %Y')}: #{research['url']}"]
      lines << research['summary'] if research['summary'].present?
      lines << "Brands: #{research['brands'].join(', ')}" if research['brands'].present?
      lines << "Homes listed: about #{research['homes_listed']}" if research['homes_listed'].present?
      lines << "Locations: #{research['locations'].join('; ')}" if research['locations'].present?
      lines << "Website built on: #{research['site_platform'].join(', ')}" if research['site_platform'].present?
      if research['seo_score']
        lines << "Search checkup: #{research['seo_score']} of 100#{". Gaps: #{research['seo_gaps'].join('; ')}" if research['seo_gaps'].present?}"
      end
      lines << "Facebook: #{research.dig('social', 'facebook')}" if research.dig('social', 'facebook').present?
      lines << "Talking points: #{research['talking_points'].join(' | ')}" if research['talking_points'].present?
      Note.create!(content: lines.join("\n"), entity_type: 'lead', entity_id: @lead.id.to_s, created_by_name: 'Proactive Outreach',
                   category: 'general', author_type: 'staff')
      @target.update_columns(site_research: research.merge('noted_at' => Time.current.iso8601))
    end

    def normalize(website)
      website.match?(%r{\Ahttps?://}i) ? website : "https://#{website.delete_prefix('//')}"
    end
  end
end
