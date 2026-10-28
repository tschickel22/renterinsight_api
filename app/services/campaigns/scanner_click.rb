# frozen_string_literal: true

module Campaigns
  # Email security scanners (Microsoft Defender Safe Links, Proofpoint, Mimecast)
  # open every link in an incoming email to check it before the person sees it.
  # On campaign 42's first day, 46 of the 56 "clicked" emails had two or more
  # different links opened within the same second, 17 seconds to 3 minutes after
  # sending, while Vimeo recorded almost no views.
  #
  # A person cannot open two different links in an email within a couple of
  # seconds, so that burst is the one signal treated as a scanner. Anything less
  # clear (a single early click, two links some seconds apart) is still counted.
  module ScannerClick
    # Link click times are stored to the second, so this allows for rounding.
    BURST_WINDOW = 2.seconds

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
