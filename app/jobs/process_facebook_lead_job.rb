# frozen_string_literal: true

class ProcessFacebookLeadJob < ApplicationJob
  queue_as :default

  DEFAULT_FIELD_MAPPING = {
    'full_name'    => 'full_name',
    'first_name'   => 'first_name',
    'last_name'    => 'last_name',
    'email'        => 'email',
    'phone_number' => 'phone',
    'phone'        => 'phone',
    'street_address' => 'street',
    'city'         => 'city',
    'state'        => 'state',
    'zip_code'     => 'zip',
    'country'      => 'country'
  }.freeze

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

    field_data = raw['field_data'] || []
    parsed = parse_field_data(field_data)

    attrs   = map_fields(parsed, integration.field_mapping)
    survey  = build_survey_answers(parsed, integration.field_mapping)

    first_name, last_name = split_name(attrs)

    lead_attrs = {
      company_id:  integration.company_id,
      # A page with no location of its own still lands the lead somewhere a rep
      # works. See Company#inbound_lead_location.
      location_id: integration.location_id || company.inbound_lead_location&.id,
      facebook_leadgen_id: leadgen_id.to_s,
      first_name:  first_name,
      last_name:   last_name,
      email:       attrs['email'],
      phone:       attrs['phone'],
      street:      attrs['street'],
      city:        attrs['city'],
      state:       attrs['state'],
      zip:         attrs['zip'],
      country:     attrs['country'],
      status:      'new',
      source_id:   resolve_source_id(integration),
      owner_id:    resolve_owner_id(integration),
      utm_source:  'facebook',
      utm_medium:  'paid_ad',
      utm_campaign: raw['campaign_name'] || raw['campaign_id'],
      utm_content:  raw['ad_name']       || raw['ad_id'],
      social_intent: 'paid_ad',
      survey_answers: survey,
      notes: build_notes(raw, leadgen_id, form_id)
    }.compact

    # Someone already on file: fold the inquiry into their record and tell a
    # person, exactly as a Zapier lead does, instead of creating a duplicate.
    if (match = identity_match(company, lead_attrs))
      absorb_repeat_inquiry(integration, company, match, lead_attrs, survey)
      return match.record
    end

    lead = Lead.create!(lead_attrs)

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

  def parse_field_data(field_data)
    field_data.each_with_object({}) do |entry, h|
      name   = entry['name'].to_s.downcase
      values = Array(entry['values'])
      h[name] = values.length == 1 ? values.first : values
    end
  end

  def map_fields(parsed, mapping)
    mapping = (mapping.presence || {}).merge(DEFAULT_FIELD_MAPPING) { |_k, v, _d| v }
    result  = {}
    parsed.each do |fb_field, value|
      lead_field = mapping[fb_field] || DEFAULT_FIELD_MAPPING[fb_field]
      result[lead_field] = value if lead_field.present?
    end
    result
  end

  # Custom/unmapped fields become survey_answers.
  def build_survey_answers(parsed, mapping)
    mapping = (mapping.presence || {}).merge(DEFAULT_FIELD_MAPPING) { |_k, v, _d| v }
    parsed.reject { |fb_field, _| mapping.key?(fb_field) || DEFAULT_FIELD_MAPPING.key?(fb_field) }
  end

  def split_name(attrs)
    first = attrs['first_name']
    last  = attrs['last_name']
    return [first, last] if first.present? || last.present?

    full = attrs['full_name'].to_s.strip
    return [nil, nil] if full.blank?

    parts = full.split(/\s+/, 2)
    [parts[0], parts[1]]
  end

  def resolve_source_id(integration)
    return integration.default_source_id if integration.default_source_id.present?

    source = Source.find_or_create_by!(company_id: integration.company_id, name: 'Facebook') do |s|
      s.source_type = 'paid_ad'
      s.is_active   = true
    end
    integration.update_column(:default_source_id, source.id)
    source.id
  end

  def resolve_owner_id(integration)
    return integration.default_owner_id if integration.default_owner_id.present?

    # Fallback: first company admin
    User.where(company_id: integration.company_id, role: 'admin').order(:id).limit(1).pick(:id)
  end

  def trigger_default_workflow(integration, lead)
    return unless integration.default_workflow_id.present?

    rule = WorkflowRule.active.find_by(id: integration.default_workflow_id, company_id: integration.company_id)
    return unless rule
    # A rule that already listens for new leads is started by the lead.created
    # event this lead just emitted. Starting it here as well ran it twice.
    return if rule.trigger.is_a?(Hash) && rule.trigger['event_type'] == 'lead.created'

    WorkflowEngine.start_run(rule: rule, entity: lead)
  rescue => e
    Rails.logger.error "[ProcessFacebookLeadJob] trigger_default_workflow: #{e.message}"
  end

  def identity_match(company, lead_attrs)
    return nil if lead_attrs[:email].blank? && lead_attrs[:phone].blank?

    IdentityResolver.new(company, email: lead_attrs[:email], phone: lead_attrs[:phone]).resolve
  end

  def absorb_repeat_inquiry(integration, company, match, lead_attrs, survey)
    InboundInquiryAbsorber.new(
      company: company,
      source_label: ['Facebook Lead Ads', integration.page_name.presence].compact.join(': '),
      raw_answers: survey,
      # With no owner on the matched record, the page's default owner hears it.
      recipient_candidates: ->(_attrs) { [integration.default_owner_id] },
      origin: 'facebook_lead_ads'
    ).call(match, lead_attrs)
  end

  def build_notes(raw, leadgen_id, form_id)
    parts = ["Source: Facebook Lead Ad"]
    parts << "Form ID: #{form_id}" if form_id.present?
    parts << "Lead ID: #{leadgen_id}"
    parts << "Campaign: #{raw['campaign_name']}" if raw['campaign_name'].present?
    parts << "Ad: #{raw['ad_name']}" if raw['ad_name'].present?
    parts.join("\n")
  end
end
