# frozen_string_literal: true

module Marketing
  # What a dealer's website actually produced.
  #
  # The sibling of LandingPageAnalytics, scoped to a whole site rather than one
  # page, and carrying the two things a dealer asks that nothing could answer
  # before: which homes people care about, and which sources are worth the money.
  #
  # The chain is visitor -> source -> home -> lead -> deal -> gross. Every link
  # already existed in isolation. What was missing was the join, and the reason
  # it was missing is that visits were never recorded for websites at all: the
  # tracking beacon accepted landing pages only and nothing ever set trackVisits,
  # so page_visits held zero rows. Reports built on it were correct and empty.
  #
  # Gross is read from the deal, never recomputed. Deal#front_gross is the single
  # source of truth for margin and recalculating it here would produce a second
  # number that disagrees with every other screen.
  class WebsiteAnalytics
    DEFAULT_WINDOW = 30.days
    TOP_HOMES = 10

    def initialize(website, from: nil, to: nil)
      @website = website
      @to = to || Time.current
      @from = from || (@to - DEFAULT_WINDOW)
    end

    def call
      {
        window: { from: @from.iso8601, to: @to.iso8601 },
        totals: totals,
        sources: sources,
        homes: homes,
        timeseries: timeseries
      }
    end

    private

    def page_ids
      @page_ids ||= @website.website_pages.where(is_deleted: [false, nil]).pluck(:id)
    end

    # Bots excluded everywhere. A dealer comparing spend across sources cannot
    # be shown a channel inflated by crawlers.
    def visits
      @visits ||= PageVisit.real
                           .where(website_page_id: page_ids)
                           .where(first_seen_at: @from..@to)
    end

    def visit_ids
      @visit_ids ||= visits.pluck(:id)
    end

    def events
      PageVisitEvent.where(page_visit_id: visit_ids)
    end

    def totals
      identified = visits.identified.count
      {
        visits: visits.count,
        visitors: visits.distinct.count(:visitor_token),
        identified: identified,
        converted: visits.converted.count,
        # The number a dealer actually judges the site on, attributed through
        # the intake form rather than by counting every lead in the window.
        leads: leads.count,
        sold: sold_deals.count,
        gross: sold_deals.sum { |deal| deal.try(:front_gross).to_f }.round(2)
      }
    end

    # Where the traffic came from. utm_source first because that is what an ad
    # platform sets; referrer host is the fallback for organic and for links a
    # dealer never tagged, which is most of them.
    def sources
      by_source = visits.group(:utm_source).count.transform_keys { |k| k.presence || 'untagged' }
      {
        by_source: by_source,
        by_medium: visits.group(:utm_medium).count.transform_keys { |k| k.presence || 'untagged' },
        by_campaign: visits.group(:utm_campaign).count.transform_keys { |k| k.presence || 'untagged' },
        by_referrer: referrer_hosts,
        by_device: visits.group(:device_type).count.transform_keys { |k| k.presence || 'unknown' },
        # Source of the visits that became leads, which is the only source
        # ranking worth acting on. A channel sending ten times the traffic at a
        # tenth of the conversion is a worse buy, and a raw visit count hides it.
        converting: visits.converted.group(:utm_source).count
                          .transform_keys { |k| k.presence || 'untagged' }
      }
    end

    # Hosts rather than full URLs: a dealer wants to know Facebook sent them
    # traffic, not which of 400 post permalinks did.
    def referrer_hosts
      visits.where.not(referrer: [nil, '']).pluck(:referrer).each_with_object(Hash.new(0)) do |url, acc|
        host = begin
          URI.parse(url).host.to_s.sub(/\Awww\./, '').presence
        rescue StandardError
          nil
        end
        acc[host || 'unknown'] += 1
      end.sort_by { |_, count| -count }.first(15).to_h
    end

    # The question that has never been answerable: which homes are people
    # actually interested in.
    #
    # Ranked by detail opens rather than impressions, because opening a home is
    # a decision and scrolling past one is not.
    def homes
      by_vehicle = Hash.new { |h, k| h[k] = { 'home_view' => 0, 'home_detail' => 0, 'home_inquiry' => 0 } }

      events.inventory.find_each do |event|
        id = event.vehicle_id
        next if id.nil?

        by_vehicle[id][event.event_type] += 1
      end

      ranked = by_vehicle.sort_by { |_, tallies| -tallies['home_detail'] }.first(TOP_HOMES)
      vehicles = @website.company.vehicles.where(id: ranked.map(&:first)).index_by(&:id)

      ranked.filter_map do |vehicle_id, tallies|
        vehicle = vehicles[vehicle_id]
        next if vehicle.nil?

        {
          vehicle_id: vehicle_id,
          name: [vehicle.year, vehicle.make, vehicle.model].compact.join(' '),
          status: vehicle.status,
          price: vehicle.sale_price,
          views: tallies['home_view'],
          detail_views: tallies['home_detail'],
          # Inquiries come from the lead record rather than a beacon: a form
          # submit that reaches the database is a fact, where a beacon can be
          # lost to a closed tab or an ad blocker. IntakeSubmission already
          # writes vehicle_id into lead_data.
          inquiries: inquiry_counts[vehicle_id].to_i
        }
      end
    end

    # Leads whose interest names a specific home, counted per home.
    def inquiry_counts
      @inquiry_counts ||= leads.where.not(vehicle_id: nil).group(:vehicle_id).count
    rescue StandardError
      {}
    end

    # Leads this website produced.
    #
    # Attribution runs through the intake form, not through the visit. A lead is
    # ours because it arrived on a form this site renders, which is a fact
    # recorded in the database at submission time. Matching a lead back to the
    # session that produced it would depend on a beacon and a token surviving the
    # whole journey, and a lead whose beacon was blocked is still a lead.
    #
    # Not matched on source NAME: sources are per company and the real data holds
    # "Website", "Web Form", "Web Site" and "Website Contact" as separate rows, so
    # any name match would silently miss tenants who spelled it differently.
    #
    # Lead <- IntakeSubmission <- IntakeForm, with the forms taken from what this
    # site actually renders. A form used only by a landing page is not this
    # website's, which is the over-crediting this replaces.
    def leads
      @leads ||= begin
        form_ids = website_form_ids
        if form_ids.empty?
          Lead.none
        else
          lead_ids = IntakeSubmission.where(intake_form_id: form_ids)
                                     .where.not(lead_id: nil)
                                     .pluck(:lead_id)
          @website.company.leads.where(id: lead_ids, created_at: @from..@to)
        end
      end
    rescue StandardError => e
      Rails.logger.warn("[WebsiteAnalytics] lead attribution failed for #{@website.id}: #{e.message}")
      Lead.none
    end

    # Every intake form this site can submit to: the ones named in its blocks,
    # plus the company's general contact form, which is what the inventory card's
    # "Contact us about this home" button posts to and which is resolved at
    # render time rather than stored in a block.
    def website_form_ids
      @website_form_ids ||= begin
        from_blocks = @website.website_pages.where(is_deleted: [false, nil]).flat_map do |page|
          Array(page.blocks).filter_map do |block|
            next unless block.is_a?(Hash)

            content = block['content'].is_a?(Hash) ? block['content'] : block
            (content['lead_form_id'] || content['leadFormId']).presence
          end
        end

        (from_blocks.map(&:to_i) + [Websites::DefaultLeadForm.for(@website.company)&.id]).compact.uniq
      end
    end

    # Sold means whatever this tenant calls sold.
    #
    # deal.stage is a configured key, not an enum, so a hardcoded 'sold' or
    # 'closed_won' is wrong for any dealer who renamed their pipeline. Company
    # already resolves this and is the only thing that should.
    def sold_deals
      @sold_deals ||= begin
        won = Array(@website.company.won_stage_keys).presence || ['closed_won']
        @website.company.deals.where(created_at: @from..@to, stage: won)
      rescue StandardError
        Deal.none
      end
    end

    def timeseries
      visits.group('DATE(page_visits.first_seen_at)').count.map do |date, count|
        {
          date: date.to_s,
          visits: count,
          conversions: visits.converted.where('DATE(page_visits.first_seen_at) = ?', date).count
        }
      end.sort_by { |row| row[:date] }
    end
  end
end
