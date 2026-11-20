# frozen_string_literal: true

module Outreach
  # Sends one message in the sender's name and records it (backlog E105).
  class Sender
    class NotAllowed < StandardError; end

    GAPS = [1, 2, 4, 7, 7, 9].freeze

    def initialize(target)
      @target = target
      @lead = target.lead
      @company = target.company
      @settings = Settings.for(@company)
    end

    # kind: opener, follow_up or reply.
    def deliver!(body:, channel:, kind:, subject: nil, content_item: nil, report: false)
      @report = report && @target.site_research.to_h['report'].present?
      raise NotAllowed, 'Proactive Outreach is off for this company' unless @settings.active?

      conversation = conversation!
      @kind = kind
      communication = channel.to_s == 'email' ? email!(conversation, body, subject, content_item) : text!(conversation, body, kind, content_item)
      @target.record!('sent', channel: channel, communication_id: communication&.id,
                              metadata: { kind: kind, content_item_id: content_item&.id }.compact)
      note_sent(channel, kind)
      @target.update!(site_research: @target.site_research.merge('report_shared_at' => Time.current.iso8601)) if @report
      communication
    end

    def conversation!
      return @target.conversation if @target.conversation

      phone = @lead.phone.presence && Conversation.normalize_phone(@lead.phone)
      number = TwilioAccount.active.where(company_id: @company.id).order(:id).first&.phone_number
      conversation = Conversation.create!(
        company_id: @company.id, location_id: @lead.location_id, conversable: @lead,
        channel: phone && number ? 'sms' : 'email', assigned_user_id: @settings.sender&.id,
        sender_number: number, buyer_phone: phone, status: 'active', assistant_enabled: true, started_at: Time.current
      )
      @target.update!(conversation: conversation)
      conversation
    end

    private

    def text!(conversation, body, kind, item)
      message = [body, item && Tracking.video_url(@target, item), (@report ? "Your website checkup: #{Tracking.report_url(@target)}" : nil)].compact.join(' ')
      message = "#{message} Reply STOP to opt out." if kind == 'opener'
      result = Assistant::Messenger.deliver!(conversation, body: message, sent_by: 'assistant', extra_metadata: { outreach_target_id: @target.id })
      raise NotAllowed, result[:error].to_s unless result[:success]

      result[:communication]
    end

    def email!(conversation, body, subject, item)
      person = @settings.sender
      raise NotAllowed, 'No sender is chosen' unless person

      result = CommunicationService.send_email(
        communicable: @lead, to: @lead.email, subject: subject.presence || "A quick question from #{@company.name}",
        body: email_html(body, item), category: 'nurture', user: person,
        metadata: { 'sent_by' => 'assistant', 'conversation_id' => conversation.id, 'outreach_target_id' => @target.id }
      )
      raise NotAllowed, result[:error].to_s unless result[:success]

      communication = result[:communication]
      communication.update_columns(conversation_id: conversation.id)
      conversation.note_message!(communication)
      communication
    end

    def email_html(body, item)
      esc = ->(text) { ERB::Util.html_escape(text) }
      first = @lead.first_name.to_s.strip
      first = '' if first.match?(Assistant::Learn::PLACEHOLDER_NAME)
      paragraphs = body.to_s.split(/\n{2,}/).map { |p| "<p>#{esc.call(p).gsub("\n", '<br>')}</p>" }.join
      video = item ? %(<p><a href="#{esc.call(Tracking.video_url(@target, item))}">Watch: #{esc.call(item.title)}</a></p>) : ''
      video += %(<p><a href="#{esc.call(Tracking.report_url(@target))}">See your website checkup</a></p>) if @report
      booking = booking_link
      video += %(<p><a href="#{esc.call(booking)}">Pick a time for a #{@settings['demo_minutes'].to_i} minute demo</a></p>) if booking
      signature = [@settings['persona_name'], @settings['persona_title'], @company.name].compact_blank.map { |l| esc.call(l) }.join('<br>')
      footer = %(<p style="margin-top:24px;font-size:12px;color:#6b7280;">#{esc.call(@company.name)}, #{esc.call(@settings['postal_address'])}<br>) +
               %(<a href="#{esc.call(Tracking.unsubscribe_url(@target))}" style="color:#6b7280;">Unsubscribe</a></p>)
      "<p>Hi#{" #{esc.call(first)}" if first.present?},</p>#{paragraphs}#{video}<p>#{signature}</p>#{footer}"
    end

    # Openers and follow-ups by email always carry the sender's booking page
    # (Tom, 2026-11-20). Replies offer real times instead.
    def booking_link
      return nil if @kind.to_s == 'reply'

      url = @settings.sender&.booking_url.to_s.strip
      url.match?(%r{\Ahttps?://}i) ? url : nil
    end

    def note_sent(channel, kind)
      now = Time.current
      touches = @target.touch_count + 1
      attrs = { touch_count: touches, last_channel: channel.to_s, last_sent_at: now, first_sent_at: @target.first_sent_at || now }
      attrs[:status] = 'sent' if @target.status == 'sending'
      unless kind == 'reply'
        gap = GAPS[touches - 1]
        attrs[:next_touch_at] = gap ? now + gap.days : nil
        attrs[:status] = 'finished' if gap.nil? && @target.status != 'replied'
      end
      @target.update!(attrs)
    end
  end
end
