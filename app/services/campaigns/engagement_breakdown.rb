module Campaigns
  # Aggregated campaign engagement for the Recipients/Analytics tab, two views:
  #   #by_step — per step: sent/delivered/opens/clicks/replies + top links
  #   #by_link — per link: total/unique clicks + the recipients who clicked it
  #
  # Shares scoping, test-send exclusion, and the link source-of-truth with
  # Campaigns::RecipientEngagement: content links come from CampaignLinkToken,
  # attachment/document links from TrackedLink. Aggregates across a recipient's
  # drip sends. One bulk load of click rows + batched recipient enrichment — no N+1.
  class EngagementBreakdown
    STEP_SORTS = %w[clicks opens recent position].freeze
    LINK_SORTS = %w[clicks recent unique].freeze
    TOP_LINKS_PER_STEP = 5
    MAX_RECIPIENTS_PER_LINK = 25
    RECIPIENT_TABLES = { 'Lead' => Lead, 'Contact' => Contact, 'Account' => Account }.freeze

    def initialize(campaign:, sort: nil, step_id: nil, search: nil, page: 1, per_page: 50)
      @campaign = campaign
      @company  = campaign.company
      @sort     = sort.to_s
      @step_id  = step_id.presence&.to_i
      @search   = search.to_s.strip
      @page     = [page.to_i, 1].max
      @per_page = [[per_page.to_i, 1].max, 200].min
    end

    # ───────────────────────── by_step ─────────────────────────

    def by_step
      sort = STEP_SORTS.include?(@sort) ? @sort : 'clicks'

      agg_by_step = step_aggregates                 # step_id => aggregate hash
      steps       = campaign_steps_by_id            # step_id => CampaignStep
      links_by_step = top_links_by_step             # step_id => [link hash, ...]

      items = agg_by_step.map do |step_id, a|
        step = steps[step_id]
        {
          step_id:            step_id,
          position:           step&.position,
          channel:            step&.channel,
          subject:            step&.subject,
          preheader:          step&.preheader,
          sms_excerpt:        sms_excerpt(step),
          sent:               a[:sent],
          delivered:          a[:delivered],
          opens:              a[:opens],
          unique_openers:     a[:unique_openers],
          open_rate:          rate(a[:unique_openers], a[:sent]),
          clicks:             a[:clicks],
          unique_clickers:    a[:unique_clickers],
          click_rate:         rate(a[:unique_clickers], a[:sent]),
          replies:            a[:replies],
          last_engagement_at: a[:last_engagement_at],
          top_links:          (links_by_step[step_id] || []).first(TOP_LINKS_PER_STEP)
        }
      end

      items = sort_steps(items, sort)
      total = items.size
      page_items = paginate(items)

      {
        items: page_items,
        meta: {
          total: total, page: @page, per_page: @per_page,
          total_pages: total_pages(total), sort: sort,
          stats: {
            steps:        agg_by_step.size,
            total_sent:   real_sends.where.not(sent_at: nil).count,
            total_opens:  real_sends.sum(:open_count),
            total_clicks: real_sends.sum(:click_count)
          }
        }
      }
    end

    # ───────────────────────── by_link ─────────────────────────

    def by_link
      sort = LINK_SORTS.include?(@sort) ? @sort : 'clicks'

      rows = link_click_rows
      rows = rows.select { |r| r[:step_id] == @step_id } if @step_id

      groups = rows.group_by { |r| [r[:kind], r[:key], r[:step_id]] }

      items = groups.map do |(kind, _key, step_id), grp|
        by_recipient = grp.group_by { |r| r[:recipient_id] }
        recipient_aggs = by_recipient.filter_map do |rid, rr|
          next if rid.nil?
          { recipient_id: rid,
            click_count: rr.sum { |x| x[:clicks] },
            last_clicked_at: rr.filter_map { |x| x[:last_clicked_at] }.max }
        end
        {
          kind:            kind,
          label:           grp.first[:label],
          url:             grp.first[:url],
          step_id:         step_id,
          step_position:   grp.first[:step_position],
          total_clicks:    grp.sum { |x| x[:clicks] },
          unique_clickers: recipient_aggs.size,
          last_clicked_at: grp.filter_map { |x| x[:last_clicked_at] }.max,
          _recipient_aggs: recipient_aggs
        }
      end

      items = sort_links(items, sort)
      total = items.size
      page_items = paginate(items)

      recipient_info = load_recipients(page_items.flat_map { |it| it[:_recipient_aggs].first(MAX_RECIPIENTS_PER_LINK).map { |r| r[:recipient_id] } }.uniq)

      serialized = page_items.map { |it| serialize_link(it, recipient_info) }

      {
        items: serialized,
        meta: {
          total: total, page: @page, per_page: @per_page,
          total_pages: total_pages(total), sort: sort, step_id: @step_id,
          stats: {
            links:                 total,
            total_clicks:          rows.sum { |r| r[:clicks] },
            total_unique_clickers: rows.map { |r| r[:recipient_id] }.compact.uniq.size
          }
        }
      }
    end

    private

    def real_sends
      @real_sends ||= @campaign.campaign_sends.real
    end

    def recipient_type
      @recipient_type ||=
        @campaign.campaign_audience&.source_type.presence ||
        @campaign.campaign_enrollments.where.not(recipient_type: 'User').limit(1).pick(:recipient_type) ||
        'Lead'
    end

    def step_aggregates
      real_sends.group(:campaign_step_id).select(<<~SEL.squish).each_with_object({}) do |row, h|
        campaign_step_id,
        COUNT(DISTINCT campaign_enrollment_id) FILTER (WHERE sent_at IS NOT NULL)      AS sent,
        COUNT(DISTINCT campaign_enrollment_id) FILTER (WHERE delivered_at IS NOT NULL) AS delivered,
        SUM(open_count)                                                                AS opens,
        COUNT(DISTINCT campaign_enrollment_id) FILTER (WHERE opened_at IS NOT NULL)    AS unique_openers,
        SUM(click_count)                                                               AS clicks,
        COUNT(DISTINCT campaign_enrollment_id) FILTER (WHERE clicked_at IS NOT NULL)   AS unique_clickers,
        COUNT(DISTINCT campaign_enrollment_id) FILTER (WHERE replied_at IS NOT NULL)   AS replies,
        GREATEST(COALESCE(MAX(opened_at), to_timestamp(0)),
                 COALESCE(MAX(clicked_at), to_timestamp(0)))                           AS last_engagement_at
      SEL
        h[row.campaign_step_id] = {
          sent: row.sent.to_i, delivered: row.delivered.to_i,
          opens: row.opens.to_i, unique_openers: row.unique_openers.to_i,
          clicks: row.clicks.to_i, unique_clickers: row.unique_clickers.to_i,
          replies: row.replies.to_i,
          last_engagement_at: engagement_time(row.last_engagement_at)
        }
      end
    end

    def campaign_steps_by_id
      @campaign.campaign_steps.index_by(&:id)
    end

    # Flat list of every link click (content + attachment), tagged with the enrollment,
    # recipient, step, and step position. Loaded once and reused by both views.
    def link_click_rows
      @link_click_rows ||= begin
        sends = real_sends.pluck(:id, :campaign_enrollment_id, :campaign_step_id, :communication_id)
        if sends.empty?
          []
        else
          enr_of_send  = {}
          step_of_send = {}
          enr_of_comm  = {}
          step_of_comm = {}
          sends.each do |sid, eid, stid, cid|
            enr_of_send[sid]  = eid
            step_of_send[sid] = stid
            if cid
              enr_of_comm[cid]  = eid
              step_of_comm[cid] = stid
            end
          end

          rows = []

          CampaignLinkToken.where(campaign_send_id: enr_of_send.keys)
                           .where('click_count > 0')
                           .pluck(:campaign_send_id, :target_url, :click_count, :last_clicked_at)
                           .each do |sid, url, cc, lc|
            rows << { kind: 'content_link', key: "content:#{url}", label: url, url: url,
                      enrollment_id: enr_of_send[sid], step_id: step_of_send[sid],
                      clicks: cc.to_i, last_clicked_at: lc }
          end

          unless enr_of_comm.empty?
            TrackedLink.where(communication_id: enr_of_comm.keys)
                       .where('click_count > 0')
                       .pluck(:communication_id, :filename, :url, :click_count, :last_clicked_at)
                       .each do |cid, fn, url, cc, lc|
              label = fn.presence || url.presence || 'attachment'
              rows << { kind: 'attachment', key: "attachment:#{fn.presence || url}", label: label, url: url,
                        enrollment_id: enr_of_comm[cid], step_id: step_of_comm[cid],
                        clicks: cc.to_i, last_clicked_at: lc }
            end
          end

          enr_to_recipient = enrollment_recipient_map(rows.map { |r| r[:enrollment_id] }.compact.uniq)
          positions        = step_position_map
          rows.each do |r|
            r[:recipient_id]  = enr_to_recipient[r[:enrollment_id]]
            r[:step_position] = positions[r[:step_id]]
          end
          rows
        end
      end
    end

    def top_links_by_step
      link_click_rows.group_by { |r| r[:step_id] }.transform_values do |step_rows|
        step_rows.group_by { |r| [r[:kind], r[:key]] }.map do |(kind, _key), grp|
          {
            label:           grp.first[:label],
            url:             grp.first[:url],
            kind:            kind,
            clicks:          grp.sum { |x| x[:clicks] },
            unique_clickers: grp.map { |x| x[:recipient_id] }.compact.uniq.size,
            last_clicked_at: grp.filter_map { |x| x[:last_clicked_at] }.max
          }
        end.sort_by { |l| -l[:clicks] }
      end
    end

    def enrollment_recipient_map(enrollment_ids)
      return {} if enrollment_ids.empty?
      CampaignEnrollment.where(id: enrollment_ids).pluck(:id, :recipient_id).to_h
    end

    def step_position_map
      @step_position_map ||= @campaign.campaign_steps.pluck(:id, :position).to_h
    end

    # Batch-loads recipient contact info + owner names, keyed by recipient_id.
    def load_recipients(recipient_ids)
      return {} if recipient_ids.empty?
      klass = RECIPIENT_TABLES[recipient_type]
      return {} unless klass

      account = recipient_type == 'Account'
      cols    = account ? %i[id name phone email owner_id] : %i[id first_name last_name phone email owner_id]
      recs    = klass.where(id: recipient_ids).pluck(*cols)

      owner_ids = recs.map(&:last).compact.uniq
      owners = User.where(id: owner_ids).pluck(:id, :first_name, :last_name, :email).each_with_object({}) do |(id, fn, ln, em), h|
        h[id] = [fn, ln].compact.join(' ').strip.presence || em
      end
      statuses = @campaign.campaign_enrollments
                          .where(recipient_type: recipient_type, recipient_id: recipient_ids)
                          .pluck(:recipient_id, :status).to_h

      recs.each_with_object({}) do |row, h|
        if account
          id, name, phone, email, owner_id = row
          display = name
        else
          id, fn, ln, phone, email, owner_id = row
          display = [fn, ln].compact.join(' ').strip.presence || email
        end
        h[id] = { name: display, email: email, phone: phone, status: statuses[id],
                  owner_id: owner_id, owner_name: owners[owner_id],
                  link: record_link(id) }
      end
    end

    def serialize_link(item, recipient_info)
      aggs = item[:_recipient_aggs].sort_by { |r| -r[:click_count] }
      shown = aggs.first(MAX_RECIPIENTS_PER_LINK)

      recipients = shown.map do |agg|
        info = recipient_info[agg[:recipient_id]] || {}
        {
          recipient_id:    agg[:recipient_id],
          recipient_type:  recipient_type,
          name:            info[:name],
          email:           info[:email],
          phone:           info[:phone],
          owner_id:        info[:owner_id],
          owner_name:      info[:owner_name],
          status:          info[:status],
          click_count:     agg[:click_count],
          last_clicked_at: agg[:last_clicked_at],
          link:            info[:link] || record_link(agg[:recipient_id])
        }
      end

      {
        label:                item[:label],
        url:                  item[:url],
        kind:                 item[:kind],
        step_id:              item[:step_id],
        step_position:        item[:step_position],
        total_clicks:         item[:total_clicks],
        unique_clickers:      item[:unique_clickers],
        last_clicked_at:      item[:last_clicked_at],
        recipients:           recipients,
        recipients_truncated: aggs.size > MAX_RECIPIENTS_PER_LINK
      }
    end

    def sort_steps(items, sort)
      case sort
      when 'opens'    then items.sort_by { |i| -i[:opens] }
      when 'recent'   then items.sort_by { |i| -time_f(i[:last_engagement_at]) }
      when 'position' then items.sort_by { |i| i[:position] || 1 << 30 }
      else                 items.sort_by { |i| -i[:clicks] } # clicks
      end
    end

    def sort_links(items, sort)
      case sort
      when 'recent' then items.sort_by { |i| -time_f(i[:last_clicked_at]) }
      when 'unique' then items.sort_by { |i| -i[:unique_clickers] }
      else               items.sort_by { |i| -i[:total_clicks] } # clicks
      end
    end

    def paginate(items)
      items[((@page - 1) * @per_page), @per_page] || []
    end

    def total_pages(total)
      (total.to_f / @per_page).ceil
    end

    def rate(numer, denom)
      denom.to_i.zero? ? 0.0 : (numer.to_f / denom).round(4)
    end

    def sms_excerpt(step)
      return nil unless step&.channel == 'sms'
      step.sms_body.to_s.strip[0, 160].presence
    end

    def record_link(recipient_id)
      case recipient_type
      when 'Lead'    then "/crm/leads/#{recipient_id}"
      when 'Contact' then "/contacts/#{recipient_id}"
      when 'Account' then "/accounts/#{recipient_id}"
      end
    end

    def engagement_time(ts)
      return nil if ts.nil?
      t = ts.is_a?(Time) ? ts : Time.zone.parse(ts.to_s)
      return nil if t.nil? || t.year <= 1970
      t
    end

    def time_f(ts)
      ts ? ts.to_f : 0.0
    end
  end
end
