# frozen_string_literal: true

class ProcessFacebookLeadJob < ApplicationJob
  queue_as :default

  # Kept for callers that read the mapping from here.
  DEFAULT_FIELD_MAPPING = FacebookLeads::LeadBuilder::DEFAULT_FIELD_MAPPING
  LEAD_COLUMN_TARGETS   = FacebookLeads::LeadBuilder::LEAD_COLUMN_TARGETS

  def perform(page_id:, leadgen_id:, form_id: nil, ad_id: nil, adgroup_id: nil, created_time: nil)
    integration = FacebookIntegration.active.find_by(page_id: page_id.to_s)
    unless integration
      Rails.logger.warn "[ProcessFacebookLeadJob] No active FacebookIntegration for page_id=#{page_id}"
      return
    end

    # Meta can deliver the same lead more than once, and a retried job would
    # otherwise create it again. Checked before the Graph call, which it saves.
    if Lead.exists?(company_id: integration.company_id, facebook_leadgen_id: leadgen_id.to_s)
      Rails.logger.info "[ProcessFacebookLeadJob] leadgen_id=#{leadgen_id} already recorded, skipping"
      return
    end

    company = Company.find(integration.company_id)

    begin
      raw = MetaGraphApi.fetch_lead(leadgen_id, integration.page_access_token)
    rescue MetaGraphApi::ExpiredTokenError => e
      Rails.logger.error "[ProcessFacebookLeadJob] Expired token for integration ##{integration.id}: #{e.message}"
      integration.update(status: 'expired')
      return
    rescue MetaGraphApi::NotFoundError => e
      Rails.logger.warn "[ProcessFacebookLeadJob] Lead #{leadgen_id} not found: #{e.message}"
      return
    rescue MetaGraphApi::RateLimitError => e
      Rails.logger.warn "[ProcessFacebookLeadJob] Rate limited: #{e.message}"
      raise
    end

    builder = FacebookLeads::LeadBuilder.new(integration, company)
    built = builder.build(raw, leadgen_id: leadgen_id, form_id: form_id)
    lead_attrs = built.attrs

    # Someone already on file: fold the inquiry into their record and tell a
    # person, exactly as a Zapier lead does, instead of creating a duplicate.
    if (match = builder.identity_match(lead_attrs))
      # The absorber lists the raw answers itself, so hand it the metadata-only
      # note or every answer would appear twice.
      repeat_attrs = lead_attrs.merge(notes: builder.notes(raw, leadgen_id, form_id, {}))
      absorb_repeat_inquiry(integration, builder, company, match, repeat_attrs, built)
      return match.record
    end

    lead = Lead.create!(lead_attrs)
    builder.write_answers_note(lead, built.answers)

    integration.with_lock do
      integration.increment!(:lead_count)
      integration.update_column(:last_lead_at, Time.current)
    end

    trigger_default_workflow(integration, lead)

    Rails.logger.info "[ProcessFacebookLeadJob] Created Lead ##{lead.id} from FB leadgen_id=#{leadgen_id}"
    lead
  rescue ActiveRecord::RecordNotUnique
    # Two deliveries of one lead raced past the check above; the other won.
    Rails.logger.info "[ProcessFacebookLeadJob] leadgen_id=#{leadgen_id} created concurrently, skipping"
    nil
  rescue => e
    Rails.logger.error "[ProcessFacebookLeadJob] Failed: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    raise
  end

  private

  def trigger_default_workflow(integration, lead)
    return unless integration.default_workflow_id.present?

    rule = WorkflowRule.active.find_by(id: integration.default_workflow_id, company_id: integration.company_id)
    return unless rule

    # Picking any of a play's rules means "run this play". Its tag rule must
    # never start here: the play's new-lead rule would start as well, and the
    # lead got two first texts, two first emails and two call tasks.
    installation = play_installation_for(rule)
    if installation
      rule = play_new_lead_rule(installation)
      return unless rule
    end

    # A new-lead rule whose conditions this lead meets is started by the
    # lead.created event the lead just emitted. Starting it here as well ran it
    # twice. One whose conditions it misses (a play for other sources, a rule
    # filtered to another source) would never run, so it starts here.
    if new_lead_rule?(rule)
      return if WorkflowEngine::ConditionEvaluator.evaluate(rule.conditions, lead, trigger: { 'id' => lead.id })
    end

    WorkflowEngine.start_run(rule: rule, entity: lead)
  rescue => e
    Rails.logger.error "[ProcessFacebookLeadJob] trigger_default_workflow: #{e.message}"
  end

  def new_lead_rule?(rule)
    rule.trigger.is_a?(Hash) && rule.trigger['event_type'] == 'lead.created'
  end

  def play_installation_for(rule)
    PlayInstallation.active.where(company_id: rule.company_id).detect do |installation|
      Array((installation.assets || {})['workflow_rule_ids']).map(&:to_i).include?(rule.id)
    end
  end

  # nil when the play has no active new-lead rule (turned off, or a kind of
  # play that doesn't start from new leads). Then nothing starts here.
  def play_new_lead_rule(installation)
    WorkflowRule.active
                .where(company_id: installation.company_id, id: Array(installation.assets['workflow_rule_ids']))
                .detect { |rule| new_lead_rule?(rule) }
  end

  def absorb_repeat_inquiry(integration, builder, company, match, lead_attrs, built)
    InboundInquiryAbsorber.new(
      company: company,
      source_label: builder.source_label,
      raw_answers: built.answers,
      # With no owner on the matched record, the page's default owner hears it.
      recipient_candidates: ->(_attrs) { [integration.default_owner_id] },
      origin: 'facebook_lead_ads'
    ).call(match, lead_attrs, cf_values: built.cf_values, cf_consumed: built.cf_consumed)
  end
end
