# frozen_string_literal: true

# Public links in Proactive Outreach messages (backlog E105). Tokens are signed,
# so a link only works for the person and video it was made for.
class OutreachTrackingController < ActionController::API
  # GET /o/v/:token
  def video
    target_id, item_id = Outreach::Tracking.read(params[:token])
    target = OutreachTarget.find_by(id: target_id)
    item = target && OutreachContentItem.find_by(id: item_id, company_id: target.company_id)
    return head(:not_found) unless item

    record_click(target, item)
    redirect_to item.url, allow_other_host: true
  end

  # GET /o/u/:token: asks first, because mail scanners open every link.
  def unsubscribe_page
    return head(:not_found) unless unsubscribe_target

    render html: page(<<~HTML.html_safe), status: :ok
      <h1>Unsubscribe</h1>
      <p>Stop receiving these messages?</p>
      <form method="post"><button type="submit">Unsubscribe</button></form>
    HTML
  end

  # POST /o/u/:token
  def unsubscribe
    target = unsubscribe_target
    return head(:not_found) unless target

    %w[email sms].each do |channel|
      CommunicationPreference.find_or_create_for(recipient: target.lead, channel: channel).opt_out!('Unsubscribed from Proactive Outreach')
    end
    target.conversation&.update!(status: 'closed', ended_at: Time.current, handoff_reason: 'opted_out')
    Outreach::Inbound.stopped(target)
    render html: page('<h1>You are unsubscribed</h1><p>You will not hear from us again.</p>'.html_safe), status: :ok
  end

  private

  def unsubscribe_target
    target_id, purpose = Outreach::Tracking.read(params[:token])
    purpose == 'unsubscribe' ? OutreachTarget.find_by(id: target_id) : nil
  end

  def record_click(target, item)
    return if request.user_agent.to_s.match?(/bot|crawler|spider|preview|scanner|facebookexternalhit|slurp/i)
    return if target.last_sent_at && target.last_channel == 'email' && target.last_sent_at > 60.seconds.ago

    target.record!('clicked', metadata: { content_item_id: item.id })
    target.update!(first_click_at: target.first_click_at || Time.current)
  rescue StandardError => e
    Rails.logger.warn("[OutreachTracking] click not recorded: #{e.message}")
  end

  def page(content)
    <<~HTML.html_safe
      <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Email preferences</title><style>body{font-family:system-ui,sans-serif;max-width:480px;margin:48px auto;padding:0 16px;color:#111827}
      button{padding:12px 20px;font-size:16px;border:0;border-radius:6px;background:#111827;color:#fff;cursor:pointer}</style></head><body>#{content}</body></html>
    HTML
  end
end
