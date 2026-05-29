module Campaigns
  # Per-recipient engagement summary for a campaign — opens, clicks, last activity,
  # and which links each recipient clicked. Built to answer "who should I call next?":
  # sort by most recent or most active and the hottest recipients float to the top.
  #
  # Aggregates at the enrollment level (a recipient can have several sends across drip
  # steps) and excludes test sends. One query for the page, then batch-loads recipient
  # owners and clicked links so the list stays cheap regardless of audience size.
  class RecipientEngagement
    SORTS = %w[recent active opens clicks recipient].freeze
    RECIPIENT_TABLES = { 'Lead' => 'leads', 'Contact' => 'contacts', 'Account' => 'accounts' }.freeze
    MAX_LINKS_PER_RECIPIENT = 10

    def initialize(campaign:, sort: 'recent', search: nil, engaged_only: false, page: 1, per_page: 50)
      @campaign     = campaign
      @company      = campaign.company
      @sort         = SORTS.include?(sort.to_s) ? sort.to_s : 'recent'
      @search       = search.to_s.strip
      @engaged_only = ActiveModel::Type::Boolean.new.cast(engaged_only)
      @page         = [page.to_i, 1].max
      @per_page     = [[per_page.to_i, 1].max, 200].min
    end

    def call
      table = RECIPIENT_TABLES[recipient_type]
      return empty_result unless table

      rel   = filtered_relation(table)
      total = rel.except(:select).count(:all)
      rows  = rel.order(Arel.sql(order_clause))
                 .limit(@per_page).offset((@page - 1) * @per_page)
                 .to_a

      enrollment_ids = rows.map(&:enrollment_id)
      links  = links_by_enrollment(enrollment_ids)
      owners = owner_names(rows)

      {
        items: rows.map { |r| serialize(r, links, owners) },
        meta: {
          total: total, page: @page, per_page: @per_page,
          total_pages: (total.to_f / @per_page).ceil,
          sort: @sort, engaged_only: @engaged_only,
          stats: stats
        }
      }
    end

    private

    def recipient_type
      @recipient_type ||=
        @campaign.campaign_audience&.source_type.presence ||
        @campaign.campaign_enrollments.where.not(recipient_type: 'User').limit(1).pick(:recipient_type) ||
        'Lead'
    end

    # Aggregated sends per enrollment, respecting the .real (non-test) scope.
    def aggregate_sql
      @campaign.campaign_sends.real
               .group(:campaign_enrollment_id)
               .select(<<~SEL.squish)
                 campaign_enrollment_id,
                 SUM(open_count)  AS opens,
                 SUM(click_count) AS clicks,
                 MAX(opened_at)   AS last_open_at,
                 MAX(clicked_at)  AS last_click_at,
                 MAX(sent_at)     AS last_sent_at,
                 COUNT(*)         AS send_count,
                 GREATEST(COALESCE(MAX(opened_at), to_timestamp(0)),
                          COALESCE(MAX(clicked_at), to_timestamp(0))) AS last_engagement_at
               SEL
               .to_sql
    end

    def base_relation(table)
      CampaignEnrollment
        .where(campaign_id: @campaign.id, recipient_type: recipient_type)
        .joins("INNER JOIN (#{aggregate_sql}) agg ON agg.campaign_enrollment_id = campaign_enrollments.id")
        .joins("INNER JOIN #{table} r ON r.id = campaign_enrollments.recipient_id")
        .select(select_columns)
    end

    def select_columns
      name_expr =
        if recipient_type == 'Account'
          'r.name'
        else
          "TRIM(COALESCE(r.first_name,'') || ' ' || COALESCE(r.last_name,''))"
        end

      [
        'campaign_enrollments.id AS enrollment_id',
        'campaign_enrollments.recipient_id AS recipient_id',
        'campaign_enrollments.email_address_snapshot AS email',
        'campaign_enrollments.status AS status',
        "#{name_expr} AS recipient_name",
        'r.phone AS phone',
        'r.owner_id AS owner_id',
        'agg.opens AS opens', 'agg.clicks AS clicks',
        'agg.last_open_at AS last_open_at', 'agg.last_click_at AS last_click_at',
        'agg.last_sent_at AS last_sent_at', 'agg.send_count AS send_count',
        'agg.last_engagement_at AS last_engagement_at'
      ].join(', ')
    end

    def filtered_relation(table)
      rel = base_relation(table)
      rel = rel.where('agg.opens > 0 OR agg.clicks > 0') if @engaged_only

      if @search.present?
        p = "%#{ActiveRecord::Base.sanitize_sql_like(@search)}%"
        rel = if recipient_type == 'Account'
                rel.where('r.name ILIKE :p OR r.phone ILIKE :p OR campaign_enrollments.email_address_snapshot ILIKE :p', p: p)
              else
                rel.where('r.first_name ILIKE :p OR r.last_name ILIKE :p OR r.phone ILIKE :p OR campaign_enrollments.email_address_snapshot ILIKE :p', p: p)
              end
      end
      rel
    end

    def order_clause
      case @sort
      when 'active'    then '(agg.opens + agg.clicks) DESC, agg.last_engagement_at DESC'
      when 'opens'     then 'agg.opens DESC, agg.last_open_at DESC NULLS LAST'
      when 'clicks'    then 'agg.clicks DESC, agg.last_click_at DESC NULLS LAST'
      when 'recipient' then 'recipient_name ASC'
      else                  'agg.last_engagement_at DESC, agg.last_sent_at DESC' # recent
      end
    end

    # Maps each enrollment to the links its recipient clicked (campaign content links via
    # CampaignLinkToken + attachment/document links via TrackedLink), top N by clicks.
    def links_by_enrollment(enrollment_ids)
      return {} if enrollment_ids.empty?

      send_to_enr = {}
      comm_to_enr = {}
      @campaign.campaign_sends
               .where(campaign_enrollment_id: enrollment_ids)
               .pluck(:id, :campaign_enrollment_id, :communication_id)
               .each do |sid, eid, cid|
        send_to_enr[sid] = eid
        comm_to_enr[cid] = eid if cid
      end

      links = Hash.new { |h, k| h[k] = [] }

      CampaignLinkToken.where(campaign_send_id: send_to_enr.keys)
                       .where('click_count > 0')
                       .pluck(:campaign_send_id, :target_url, :click_count, :last_clicked_at)
                       .each do |sid, url, cc, lc|
        eid = send_to_enr[sid]
        links[eid] << { label: url, url: url, clicks: cc.to_i, last_clicked_at: lc, kind: 'link' }
      end

      unless comm_to_enr.empty?
        TrackedLink.where(communication_id: comm_to_enr.keys)
                   .where('click_count > 0')
                   .pluck(:communication_id, :filename, :url, :link_type, :click_count, :last_clicked_at)
                   .each do |cid, fn, url, lt, cc, lc|
          eid = comm_to_enr[cid]
          links[eid] << { label: (fn.presence || url.presence || lt.to_s), url: url, clicks: cc.to_i, last_clicked_at: lc, kind: (lt.presence || 'attachment') }
        end
      end

      links.transform_values { |arr| arr.sort_by { |l| -l[:clicks] }.first(MAX_LINKS_PER_RECIPIENT) }
    end

    def owner_names(rows)
      ids = rows.map(&:owner_id).compact.uniq
      return {} if ids.empty?
      User.where(id: ids).pluck(:id, :first_name, :last_name, :email).each_with_object({}) do |(id, fn, ln, em), h|
        h[id] = [fn, ln].compact.join(' ').strip.presence || em
      end
    end

    def serialize(r, links, owners)
      name = r.recipient_name.to_s.strip
      name = r.email if name.blank?

      {
        enrollment_id:      r.enrollment_id,
        recipient_type:     recipient_type,
        recipient_id:       r.recipient_id,
        name:               name,
        email:              r.email,
        phone:              r.phone,
        status:             r.status,
        owner_id:           r.owner_id,
        owner_name:         (owners[r.owner_id] if r.owner_id),
        opens:              r.opens.to_i,
        clicks:             r.clicks.to_i,
        send_count:         r.send_count.to_i,
        last_open_at:       r.last_open_at,
        last_click_at:      r.last_click_at,
        last_engagement_at: engagement_time(r.last_engagement_at),
        last_sent_at:       r.last_sent_at,
        clicked_links:      links[r.enrollment_id] || [],
        link:               record_link(r.recipient_id)
      }
    end

    # last_engagement_at is GREATEST(..., epoch); treat an epoch value as "no engagement".
    def engagement_time(ts)
      return nil if ts.nil?
      t = ts.is_a?(Time) ? ts : Time.zone.parse(ts.to_s)
      return nil if t.nil? || t.year <= 1970
      t
    end

    def record_link(recipient_id)
      case recipient_type
      when 'Lead'    then "/crm/leads/#{recipient_id}"
      when 'Contact' then "/contacts/#{recipient_id}"
      when 'Account' then "/accounts/#{recipient_id}"
      end
    end

    def stats
      sends = @campaign.campaign_sends.real
      {
        recipients: sends.distinct.count(:campaign_enrollment_id),
        opened:     sends.where.not(opened_at: nil).distinct.count(:campaign_enrollment_id),
        clicked:    sends.where.not(clicked_at: nil).distinct.count(:campaign_enrollment_id)
      }
    end

    def empty_result
      { items: [], meta: { total: 0, page: @page, per_page: @per_page, total_pages: 0,
                           sort: @sort, engaged_only: @engaged_only,
                           stats: { recipients: 0, opened: 0, clicked: 0 } } }
    end
  end
end
