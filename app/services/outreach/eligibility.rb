# frozen_string_literal: true

module Outreach
  # Who may be contacted (backlog E105). Checked when a wave is chosen and again
  # right before every message, because a lead can join a campaign, opt out or
  # book a demo in between.
  class Eligibility
    Reach = Struct.new(:text, :email, keyword_init: true) do
      def any? = text || email
    end

    RECENT_WORK = 30.days
    EMAIL = /\A[^@\s]+@[^@\s]+\.[a-z]{2,}\z/i

    def initialize(company)
      @company = company
    end

    # Leads nobody is already working. Reachability is checked per lead (#reach).
    def scope
      leads = @company.leads.where(is_converted: [false, nil]).where(status: ['new', nil, '']).where.not(owner_id: nil)
      blocked_lead_ids.each { |ids| leads = leads.where.not(id: ids) }
      leads
    end

    def reach(lead)
      Reach.new(text: textable?(lead), email: emailable?(lead))
    end

    # Why this lead must not get the first message, or nil.
    # override: Tom added this person by hand past the soft rules
    # (OutreachTarget#override_reason), so only the hard ones still apply.
    def blocked_reason(lead, override: false)
      return 'became a customer' if lead.is_converted == true
      return 'no longer a new lead' unless override || lead.status.to_s.in?(['new', ''])
      return 'on a campaign, nurture or workflow' if !override && on_automation?(lead)
      return 'already in a conversation' if Conversation.open_now.where(conversable: lead).exists?
      return 'has a demo booked' if Assistant::Appointments.upcoming_for(lead, limit: 1).any?
      return 'cannot be reached' unless reach(lead).any?

      nil
    end

    # Why follow-ups to someone already in outreach must end, or nil.
    def stop_reason(lead, override: false)
      return 'became a customer' if lead.is_converted == true
      return 'lead closed' if Assistant::FollowUp::STOP_STATUSES.include?(lead.status.to_s) || lead.status.to_s == 'closed_lost'
      return 'opted out' if opted_out?(lead)
      return 'on a campaign, nurture or workflow' if !override && on_automation?(lead)
      return 'has a demo booked' if Assistant::Appointments.upcoming_for(lead, limit: 1).any?
      return 'cannot be reached' unless reach(lead).any?

      nil
    end

    # Why a lead matching the audience was left out, in plain words, and
    # whether Tom may add them anyway. Hard reasons are law or would put two
    # senders on one person; the rest are judgment calls he can override.
    def skip_info(lead)
      hard = hard_reason(lead)
      return { reason: hard, can_add: false } if hard

      soft = soft_reason(lead)
      soft && { reason: soft, can_add: true }
    end

    def skip_reason(lead)
      skip_info(lead)&.dig(:reason)
    end

    def hard_reason(lead)
      return 'Converted to a customer' if lead.is_converted == true
      if CampaignEnrollment.where(company_id: @company.id, recipient_type: 'Lead', recipient_id: lead.id, status: %w[unsubscribed complained]).exists? || opted_out?(lead)
        return 'Unsubscribed or opted out'
      end
      return 'In an open Quinn conversation. Close it on the lead first' if Conversation.open_now.where(conversable: lead).exists?
      return 'Has a demo booked' if Assistant::Appointments.upcoming_for(lead, limit: 1).any?
      if OutreachTarget.where(company_id: @company.id, lead_id: lead.id, status: %w[approved sending sent replied booked]).exists?
        return 'Already being contacted by another outreach wave'
      end
      return 'No usable email and no text consent' unless reach(lead).any?

      nil
    end

    def soft_reason(lead)
      return "Status is #{lead.status.to_s.humanize}, not New" unless lead.status.to_s.in?(['new', ''])
      return 'Has no owner' if lead.owner_id.nil?

      enrollment = CampaignEnrollment.where(company_id: @company.id, recipient_type: 'Lead', recipient_id: lead.id, status: %w[pending active])
                                     .order(updated_at: :desc).first || recurring_enrollments.where(recipient_id: lead.id).first
      return "On the campaign #{Campaign.find_by(id: enrollment.campaign_id)&.name || 'unnamed'}" if enrollment

      nurture = NurtureEnrollment.where(enrollable_type: 'Lead', enrollable_id: lead.id, status: %w[running paused]).order(updated_at: :desc).first
      if nurture
        name = NurtureSequence.find_by(id: nurture.nurture_sequence_id)&.name || 'a nurture'
        return "On the nurture #{name}#{' (paused, which still counts)' if nurture.status == 'paused'}"
      end

      return 'In a running workflow or play' if WorkflowRun.where(company_id: @company.id, entity_type: 'Lead', entity_id: lead.id,
                                                                  status: %w[pending running waiting paused]).exists?
      return 'In an earlier outreach wave' if OutreachTarget.where(company_id: @company.id, lead_id: lead.id).exists?

      activity = LeadActivity.where(lead_id: lead.id).where('created_at >= ?', RECENT_WORK.ago).order(created_at: :desc).first
      return "#{activity.activity_type.to_s.humanize} logged #{activity.created_at.strftime('%b %-d')}, within 30 days" if activity

      inbound = Communication.where(company_id: @company.id, communicable_type: 'Lead', communicable_id: lead.id, direction: 'inbound')
                             .where('created_at >= ?', RECENT_WORK.ago).order(created_at: :desc).first
      return "Wrote to you #{inbound.created_at.strftime('%b %-d')}, within 30 days" if inbound

      nil
    end

    def opted_out?(lead)
      sms_opted_out?(lead) || email_opted_out?(lead)
    end

    def on_automation?(lead)
      CampaignEnrollment.where(company_id: @company.id, recipient_type: 'Lead', recipient_id: lead.id, status: %w[pending active]).exists? ||
        recurring_enrollments.where(recipient_id: lead.id).exists? ||
        NurtureEnrollment.where(enrollable_type: 'Lead', enrollable_id: lead.id, status: %w[running paused]).exists? ||
        WorkflowRun.where(company_id: @company.id, entity_type: 'Lead', entity_id: lead.id, status: %w[pending running waiting paused]).exists?
    end

    private

    # Finished last cycle of a live recurring digest: it starts them again.
    def recurring_enrollments
      live = Campaign.where(company_id: @company.id, campaign_type: 'recurring_digest', status: %w[scheduled running])
                     .where.not(recurrence_cron: [nil, '']).where(is_deleted: [false, nil])
      CampaignEnrollment.where(company_id: @company.id, recipient_type: 'Lead', status: 'completed', campaign_id: live.select(:id))
    end

    def blocked_lead_ids
      [
        # A paused enrollment is not sending: that is how a person is taken out of a campaign.
        CampaignEnrollment.where(company_id: @company.id, recipient_type: 'Lead', status: %w[pending active unsubscribed complained]).select(:recipient_id),
        recurring_enrollments.select(:recipient_id),
        NurtureEnrollment.where(enrollable_type: 'Lead', status: %w[running paused]).select(:enrollable_id),
        WorkflowRun.where(company_id: @company.id, entity_type: 'Lead', status: %w[pending running waiting paused]).select(:entity_id),
        Conversation.open_now.where(company_id: @company.id, conversable_type: 'Lead').select(:conversable_id),
        OutreachTarget.where(company_id: @company.id).select(:lead_id),
        LeadActivity.where(lead_id: @company.leads.select(:id)).where('created_at >= ?', RECENT_WORK.ago).select(:lead_id),
        Communication.where(company_id: @company.id, communicable_type: 'Lead', direction: 'inbound').where('created_at >= ?', RECENT_WORK.ago).select(:communicable_id)
      ]
    end

    def phone_digits(lead)
      lead.phone.to_s.gsub(/\D/, '').last(10).to_s
    end

    def textable?(lead)
      return false unless phone_digits(lead).length == 10 && lead.may_text_about_inquiry
      return false if sms_opted_out?(lead)

      # A number that already failed will fail again, and carriers count it.
      !Communication.where(company_id: @company.id, communicable: lead, channel: 'sms', direction: 'outbound', status: %w[failed undelivered]).exists?
    end

    def emailable?(lead)
      return false unless lead.email.to_s.match?(EMAIL) && !email_opted_out?(lead) && !CampaignSuppression.unmailable?(@company.id, lead.email)

      # An address that bounced will bounce again, and it hurts the sender's mail.
      !Communication.where(company_id: @company.id, communicable: lead, channel: 'email', direction: 'outbound', status: 'bounced')
                    .where('LOWER(communications.to_address) = ?', lead.email.to_s.downcase).exists?
    end

    def sms_opted_out?(lead)
      return false if lead.phone.blank?

      CommunicationOptOut.check(channel: 'sms', company: @company, record: lead, address: lead.phone).opted_out? ||
        CampaignSuppression.suppressed?(@company.id, lead.phone)
    end

    def email_opted_out?(lead)
      return false if lead.email.blank?

      CommunicationOptOut.check(channel: 'email', company: @company, record: lead, address: lead.email).opted_out? ||
        CampaignSuppression.suppressed?(@company.id, lead.email)
    end
  end
end
