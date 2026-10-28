# frozen_string_literal: true

# Counts a campaign link click a few seconds after it happens, once the rest of
# a scanner's burst has had time to land on the email's other links. The
# redirect itself never waits for this. See Campaigns::ScannerClick.
class CountCampaignClickJob < ApplicationJob
  queue_as :default

  DELAY = 5.seconds

  def perform(token_id, clicked_at)
    token = CampaignLinkToken.find_by(id: token_id)
    cs = token&.campaign_send
    return unless cs

    at = Time.zone.at(clicked_at.to_f)
    return record_scanner(cs, at) if Campaigns::ScannerClick.burst?(token, at)

    # A click implies an open (see CampaignSend.record_click_for_communication).
    CampaignSend.record_click_for_send(cs, url: token.target_url)
  end

  private

  # Kept on the send so a scanner hit can be told apart from no click at all.
  def record_scanner(cs, at)
    meta = (cs.metadata || {}).deep_stringify_keys
    meta['scanner_clicks'] = meta['scanner_clicks'].to_i + 1
    meta['scanner_last_click_at'] = at.iso8601
    cs.update_columns(metadata: meta)
  end
end
