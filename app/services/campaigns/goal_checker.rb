module Campaigns
  class GoalChecker
    def initialize(campaign:)
      @campaign = campaign
    end

    def run
      return 0 if @campaign.goal_config.blank?

      goals = (Array(@campaign.goal_config['primary_goal']) + Array(@campaign.goal_config['additional_goals'])).compact.uniq
      return 0 if goals.empty?

      total_marked = 0
      @campaign.campaign_enrollments.where(status: %w[pending active paused]).find_each do |enrollment|
        goals.each do |goal|
          if goal_met?(enrollment, goal)
            mark_goal_met(enrollment, goal)
            total_marked += 1
            break
          end
        end
      end

      total_marked
    end

    private

    def goal_met?(enrollment, goal)
      case goal.to_s
      when 'opened'              then CampaignSend.where(campaign_enrollment_id: enrollment.id).where.not(opened_at: nil).exists?
      when 'clicked'             then CampaignSend.where(campaign_enrollment_id: enrollment.id).where.not(clicked_at: nil).exists?
      when 'replied'             then CampaignSend.where(campaign_enrollment_id: enrollment.id).where.not(replied_at: nil).exists?
      when 'form_submitted'      then form_submitted?(enrollment)
      when 'deal_created'        then deal_created?(enrollment)
      when 'deal_stage_advanced' then deal_stage_advanced?(enrollment)
      when 'unit_sold'           then unit_sold?(enrollment)
      else false
      end
    end

    def form_submitted?(enrollment)
      return false unless defined?(IntakeSubmission)
      since = enrollment.created_at
      email = enrollment.email_address_snapshot.to_s.downcase
      return false if email.blank?
      IntakeSubmission.where(company_id: @campaign.company_id)
        .where('created_at >= ?', since)
        .where("LOWER(data ->> 'email') = ?", email)
        .exists?
    rescue
      false
    end

    def deal_created?(enrollment)
      return false unless defined?(Deal)
      since = enrollment.created_at
      scope = Deal.where(company_id: @campaign.company_id).where('created_at >= ?', since)
      scope = scope_by_recipient(scope, enrollment)
      return false if scope.nil?
      scope.exists?
    rescue
      false
    end

    def deal_stage_advanced?(enrollment)
      target_stage = @campaign.goal_config.dig('thresholds', 'deal_stage_advanced', 'target_stage')
      return false if target_stage.blank?
      return false unless defined?(Deal)
      since = enrollment.created_at
      scope = Deal.where(company_id: @campaign.company_id).where(stage: target_stage)
      scope = scope_by_recipient(scope, enrollment)
      return false if scope.nil?
      scope.where('updated_at >= ?', since).exists?
    rescue
      false
    end

    def unit_sold?(enrollment)
      return false unless defined?(Deal)
      since = enrollment.created_at
      scope = Deal.where(company_id: @campaign.company_id).where(stage: 'won')
      scope = scope_by_recipient(scope, enrollment)
      return false if scope.nil?
      scope.where('updated_at >= ?', since).exists?
    rescue
      false
    end

    def scope_by_recipient(scope, enrollment)
      case enrollment.recipient_type
      when 'Lead'
        return nil unless Deal.column_names.include?('lead_id')
        scope.where(lead_id: enrollment.recipient_id)
      when 'Contact'
        col = %w[primary_contact_id contact_id].find { |c| Deal.column_names.include?(c) }
        return nil unless col
        scope.where(col => enrollment.recipient_id)
      when 'Account'
        return nil unless Deal.column_names.include?('account_id')
        scope.where(account_id: enrollment.recipient_id)
      else
        nil
      end
    end

    def mark_goal_met(enrollment, goal)
      return if enrollment.status == 'goal_met'
      enrollment.update!(status: 'goal_met', goal_met_at: Time.current, goal_met_reason: goal.to_s)
      CampaignEvent.create!(
        company_id: @campaign.company_id, campaign_id: @campaign.id,
        campaign_enrollment_id: enrollment.id,
        event_type: 'goal_met', occurred_at: Time.current,
        payload: { reason: goal.to_s }
      )
      if defined?(WebhookService)
        WebhookService.fire(
          company_id: @campaign.company_id, event: 'campaign.goal_met',
          payload: { campaign_id: @campaign.id, enrollment_id: enrollment.id, goal: goal.to_s }
        )
      end
    end
  end
end
