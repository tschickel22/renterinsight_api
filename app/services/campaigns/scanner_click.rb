# frozen_string_literal: true

module Campaigns
  # Email security scanners (Microsoft Defender Safe Links, Proofpoint, Mimecast)
  # open every link in an incoming email to check it before the person sees it.
  # On campaign 42's first day, 46 of the 56 "clicked" emails had two or more
  # different links opened within the same second, 17 seconds to 3 minutes after
  # sending, while Vimeo recorded almost no views.
  #
  # A person cannot open two different links in an email within a few seconds,
  # so that burst is the first signal treated as a scanner. Scanners also come
  # back: on campaign 42 the same email was re-checked one link at a time
  # minutes after the burst, so a later click from the network the burst came
  # from is the scanner too. Anything less clear (a lone click from a new
  # address, two links well apart) is still counted as a person.
  module ScannerClick
    # Measured bursts spread over up to 5 seconds; click times are stored to the
    # second, so this also allows for rounding.
    BURST_WINDOW = 5.seconds
    MAX_REMEMBERED_NETWORKS = 10
    # Campaign 42's re-checks came 3 to 5 minutes after the burst. Matching the
    # network only for a while keeps a person behind the same office address as
    # an on-site scanner from being hidden for good.
    REVISIT_WINDOW = 15.minutes

    # The visitor's own address. Requests reach us through Render's Cloudflare
    # edge, so request.remote_ip is a Cloudflare address, the same for everyone.
    def self.client_ip(request)
      cf = request.headers['CF-Connecting-IP'].to_s.strip
      return cf if cf.present?

      forwarded = request.headers['X-Forwarded-For'].to_s.split(',').first.to_s.strip
      forwarded.presence || request.remote_ip
    end

    # /24 for IPv4, /64 for IPv6: a scanner's re-check rarely comes from the
    # exact same address, but it comes from the same block.
    def self.network(ip)
      return nil if ip.blank?

      addr = IPAddr.new(ip)
      addr.mask(addr.ipv4? ? 24 : 64).to_s
    rescue IPAddr::InvalidAddressError
      nil
    end

    def self.known_scanner_network?(send, ip, at = Time.current)
      net = network(ip)
      return false if net.blank?

      meta = send.metadata || {}
      last = meta['scanner_last_click_at'].presence && Time.zone.parse(meta['scanner_last_click_at'])
      return false if last.nil? || at - last > REVISIT_WINDOW

      Array(meta['scanner_networks']).include?(net)
    end

    def self.burst?(token, at)
      from = at - BURST_WINDOW
      to = at + BURST_WINDOW
      CampaignLinkToken
        .where(campaign_send_id: token.campaign_send_id)
        .where.not(id: token.id)
        .where('first_clicked_at BETWEEN :from AND :to OR last_clicked_at BETWEEN :from AND :to', from: from, to: to)
        .exists?
    end

    # Sends already counted as clicked whose every click was one burst: two or
    # more links, all opened within BURST_WINDOW. Used to correct history; a
    # send with any click outside the burst is left alone.
    def self.scanner_only_send_ids(sends)
      CampaignLinkToken
        .where(campaign_send_id: sends.where.not(clicked_at: nil).select(:id))
        .where('click_count > 0')
        .group(:campaign_send_id)
        .having('COUNT(*) >= 2')
        .having('EXTRACT(EPOCH FROM (MAX(last_clicked_at) - MIN(first_clicked_at))) <= ?', BURST_WINDOW.to_i)
        .pluck(:campaign_send_id)
    end

    def self.reclassify!(sends)
      ids = scanner_only_send_ids(sends)
      CampaignSend.where(id: ids).find_each do |cs|
        meta = (cs.metadata || {}).deep_stringify_keys
        meta['scanner_clicks'] = meta['scanner_clicks'].to_i + cs.click_count.to_i
        meta['scanner_reclassified_at'] = Time.current.iso8601
        cs.update_columns(clicked_at: nil, click_count: 0, metadata: meta)
      end
      ids.size
    end
  end
end
