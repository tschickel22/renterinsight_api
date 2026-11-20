# frozen_string_literal: true

# Public links in Proactive Outreach messages (backlog E105). Tokens are signed,
# so a link only works for the person and video it was made for.
class OutreachTrackingController < ActionController::API
  # GET /o/v/:token
  def video
    target_id, item_id = Outreach::Tracking.read_video(params[:token])
    target = OutreachTarget.find_by(id: target_id)
    item = target && OutreachContentItem.find_by(id: item_id, company_id: target.company_id)
    return head(:not_found) unless item

    record_click(target, item, channel: params[:token].to_s.match?(Outreach::Tracking::SHORT) ? 'text' : 'email')
    redirect_to item.url, allow_other_host: true
  end

  # GET /o/r/:token: their website checkup. What is wrong and what it costs
  # them, never which pages or how to fix it (Outreach::SiteResearch#shareable_report).
  def report
    target_id, purpose = Outreach::Tracking.read(params[:token])
    target = purpose == 'report' ? OutreachTarget.find_by(id: target_id) : nil
    data = target&.site_research.to_h
    return head(:not_found) unless target && data['report'].present?

    record_report_view(target)
    render html: report_page(target, data), status: :ok
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

  def machine_visit?(target)
    reason = Outreach::LinkVisit.machine_reason(target, ip: visitor_ip, user_agent: request.user_agent)
    Rails.logger.info("[OutreachTracking] target #{target.id}: not counted (#{reason}) #{visitor_ip} #{request.user_agent.to_s.truncate(120)}") if reason
    reason.present?
  end

  def visitor_ip
    @visitor_ip ||= Campaigns::ScannerClick.client_ip(request)
  end

  def visit_metadata
    { ip: visitor_ip, user_agent: request.user_agent.to_s.truncate(200) }
  end

  def unsubscribe_target
    target_id, purpose = Outreach::Tracking.read(params[:token])
    purpose == 'unsubscribe' ? OutreachTarget.find_by(id: target_id) : nil
  end

  # Link previews and spam checks open the link before the person sees the
  # message (Outreach::LinkVisit). Only a person counts, and only a person
  # moves their next message forward.
  def record_click(target, item, channel:)
    return if machine_visit?(target)

    Outreach::Engagement.interested!(target)
    target.record!('clicked', channel: channel, metadata: visit_metadata.merge(content_item_id: item.id))
    target.update!(first_click_at: target.first_click_at || Time.current)
  rescue StandardError => e
    Rails.logger.warn("[OutreachTracking] click not recorded: #{e.message}")
  end

  def record_report_view(target)
    return if machine_visit?(target)
    return if target.recorded?('report_viewed')

    Outreach::Engagement.interested!(target)
    target.record!('report_viewed', metadata: visit_metadata)
  rescue StandardError => e
    Rails.logger.warn("[OutreachTracking] report view not recorded: #{e.message}")
  end

  def report_page(target, data)
    esc = ->(text) { ERB::Util.html_escape(text.to_s) }
    report = data['report']
    settings = Outreach::Settings.for(target.company)
    person = settings['persona_name'].presence || target.company.name
    host = URI(data['url'].to_s).host.to_s.delete_prefix('www.') rescue data['url'].to_s
    score = report['score'].to_i
    tone = score >= 80 ? '#15803d' : (score >= 60 ? '#b45309' : '#b91c1c')
    areas = Array(report['areas']).map do |area|
      count = area['affected_count'].to_i
      pages = count.positive? ? " <span class=\"n\">#{count} #{count == 1 ? 'page' : 'pages'}</span>" : ''
      badge = area['status'] == 'fail' ? '<span class="b f">Needs work</span>' : '<span class="b w">Could be better</span>'
      "<li><div class=\"h\">#{esc.call(area['label'])}#{pages} #{badge}</div>#{"<p>#{esc.call(area['consequence'].to_s.capitalize)}.</p>" if area['consequence'].present?}</li>"
    end.join
    page(<<~HTML.html_safe, title: "Website checkup for #{host}")
      <p class="k">Website checkup</p>
      <h1>#{esc.call(host)}</h1>
      <div class="s"><span style="color:#{tone}">#{score}</span><small> of 100</small></div>
      <p class="m">How well the site is set up for Google and AI assistants to read. #{report['pages_checked'].to_i} pages checked,
      #{report['passed'].to_i} checks passed#{", AI search #{report['ai_score'].to_i} of 100" if report['ai_score']}.</p>
      #{"<h2>What we found</h2><ul>#{areas}</ul>" if areas.present?}
      <p>#{esc.call(report['meaning'])}</p>
      <div class="c"><p><strong>Want the full report?</strong> It names every page and what to change, and shows your own site with TrueBuild,
      so buyers can design and price a home right on it. Just reply to my message and I will put it together for you.</p>
      <p>#{esc.call(person)}<br>#{esc.call(target.company.name)}</p></div>
      <p class="x">Our own checkup of the site's technical setup, not a Google ranking. It does not measure reviews, backlinks or current rankings.</p>
    HTML
  end

  def page(content, title: 'Email preferences')
    <<~HTML.html_safe
      <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
      <title>#{ERB::Util.html_escape(title)}</title><style>body{font-family:system-ui,sans-serif;max-width:560px;margin:40px auto;padding:0 16px;color:#111827;line-height:1.5;background:#fff}
      button{padding:12px 20px;font-size:16px;border:0;border-radius:6px;background:#111827;color:#fff;cursor:pointer}
      h1{margin:0 0 8px;font-size:26px;overflow-wrap:anywhere}h2{font-size:18px;margin-top:28px}.k{margin:0;color:#6b7280;text-transform:uppercase;font-size:12px;letter-spacing:.06em}
      .s{font-size:56px;font-weight:700;line-height:1}.s small{font-size:18px;color:#6b7280;font-weight:400}.m{color:#374151}
      ul{list-style:none;padding:0}li{border:1px solid #e5e7eb;border-radius:8px;padding:12px;margin:8px 0}li p{margin:6px 0 0;color:#374151}
      .h{font-weight:600}.n{font-weight:400;color:#6b7280}.b{font-size:12px;font-weight:600;padding:2px 8px;border-radius:999px;margin-left:4px;white-space:nowrap}
      .f{background:#fee2e2;color:#991b1b}.w{background:#fef3c7;color:#92400e}.c{background:#f3f4f6;border-radius:8px;padding:4px 16px;margin-top:24px}
      .x{font-size:12px;color:#6b7280;margin-top:24px}</style></head><body>#{content}</body></html>
    HTML
  end
end
