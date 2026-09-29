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

  # Lead columns a dealer may point a Facebook question at. One list with the
  # intake form builder, because the FB settings page offers the same menu
  # (GET /api/crm/intake/forms/lead_fields). full_name is FB's own combined
  # field, which split_name breaks apart.
  LEAD_COLUMN_TARGETS = (
    Api::Crm::Intake::FormsController::STANDARD_LEAD_FIELDS.map { |f| f[:name] } - %w[opt_in_sms notes] +
    %w[full_name]
  ).freeze

  # Targets that keep the answer as a question-and-answer pair rather than a
  # column value. 'notes' and 'survey_answers' are the same thing now: every
  # such answer lands in both, so a dealer sees it on the lead either way.
  ANSWER_TARGETS = %w[notes survey_answers].freeze
  IGNORE_TARGET  = 'ignore'

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

    attrs, answers, cf_values, cf_consumed = route_fields(company, parsed, integration.field_mapping)

    first_name, last_name = split_name(attrs)

    # Every mapped column, not just the contact ones, so a question pointed at
    # Budget Range or Purchase Timeframe lands there.
    column_attrs = attrs.except('full_name', 'first_name', 'last_name')
                        .transform_values { |v| v.is_a?(Array) ? v.join(', ') : v }
                        .symbolize_keys

    lead_attrs = column_attrs.merge(
      company_id:  integration.company_id,
      # A page with no location of its own still lands the lead somewhere a rep
      # works. See Company#inbound_lead_location.
      location_id: integration.location_id || company.inbound_lead_location&.id,
      facebook_leadgen_id: leadgen_id.to_s,
      first_name:  first_name,
      last_name:   last_name,
      status:      'new',
      source_id:   resolve_source_id(integration),
      owner_id:    resolve_owner_id(integration),
      utm_source:  'facebook',
      utm_medium:  'paid_ad',
      utm_campaign: raw['campaign_name'] || raw['campaign_id'],
      utm_content:  raw['ad_name']       || raw['ad_id'],
      social_intent: 'paid_ad',
      survey_answers: answers.presence,
      custom_field_values: cf_values.presence,
      origin:      Lead::ORIGIN_FACEBOOK,
      notes: build_notes(raw, leadgen_id, form_id, answers)
    ).compact

    # Someone already on file: fold the inquiry into their record and tell a
    # person, exactly as a Zapier lead does, instead of creating a duplicate.
    if (match = identity_match(company, lead_attrs))
      # The absorber lists the raw answers itself, so hand it the metadata-only
      # note or every answer would appear twice.
      repeat_attrs = lead_attrs.merge(notes: build_notes(raw, leadgen_id, form_id, {}))
      absorb_repeat_inquiry(integration, company, match, repeat_attrs, answers, cf_values, cf_consumed)
      return match.record
    end

    lead = Lead.create!(lead_attrs)
    write_answers_note(lead, integration, answers)

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

  # Sort every answer into where it belongs. Returns
  #   [column_attrs, answers, custom_field_values, custom_consumed_fb_keys]
  #
  # A dealer's mapping wins. After it, the built-in contact aliases. Anything
  # still unplaced is matched against the company's lead custom fields by key
  # or label, and whatever is left is kept as a question-and-answer pair.
  # Nothing is dropped unless the dealer chose Ignore.
  def route_fields(company, parsed, mapping)
    mapping = (mapping.presence || {}).transform_keys { |k| k.to_s.downcase }
    lead_cfs = company.custom_fields.active.for_module('leads').to_a

    attrs = {}
    answers = {}
    cf_values = {}
    cf_consumed = []

    parsed.each do |fb_field, value|
      target = mapping[fb_field].to_s.presence || DEFAULT_FIELD_MAPPING[fb_field]

      next if target == IGNORE_TARGET

      if target && LEAD_COLUMN_TARGETS.include?(target)
        attrs[target] = value
        next
      end

      field =
        if target&.start_with?(IntakeForm::CUSTOM_FIELD_PREFIX)
          key = target.delete_prefix(IntakeForm::CUSTOM_FIELD_PREFIX)
          lead_cfs.find { |cf| cf.field_key.to_s == key }
        elsif target.blank?
          auto_match_custom_field(lead_cfs, fb_field)
        end

      if field && (cf_value = custom_field_value(field, value))
        cf_values[field.field_key.to_s] = cf_value
        cf_consumed << fb_field
      end

      # Custom-field answers are kept here too. The note is where a rep reads
      # what the person said, and a custom field sits on another tab.
      answers[fb_field] = value
    end

    [attrs, answers, cf_values, cf_consumed]
  end

  # Facebook sends a question's key as the question itself,
  # "what_are_you_looking_for?", while a dealer's field reads "What are you
  # looking for". Compared with punctuation stripped, like the Zapier path.
  def auto_match_custom_field(lead_cfs, fb_field)
    wanted = normalize_key(fb_field)
    return nil if wanted.blank?

    lead_cfs.find { |cf| normalize_key(cf.field_key) == wanted } ||
      lead_cfs.find { |cf| normalize_key(cf.label.presence || cf.name) == wanted }
  end

  def normalize_key(key)
    key.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
  end

  # nil when the answer doesn't fit the field's own rules (a word in a number
  # field, a choice the picklist lacks). It still reaches the note.
  def custom_field_value(field, value)
    value = value.join(', ') if value.is_a?(Array)
    return nil if value.blank?

    errors = (field.validate_value(value) rescue ['invalid'])
    errors.present? ? nil : value
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

  def identity_match(company, lead_attrs)
    return nil if lead_attrs[:email].blank? && lead_attrs[:phone].blank?

    IdentityResolver.new(company, email: lead_attrs[:email], phone: lead_attrs[:phone]).resolve
  end

  def absorb_repeat_inquiry(integration, company, match, lead_attrs, answers, cf_values, cf_consumed)
    InboundInquiryAbsorber.new(
      company: company,
      source_label: source_label(integration),
      raw_answers: answers,
      # With no owner on the matched record, the page's default owner hears it.
      recipient_candidates: ->(_attrs) { [integration.default_owner_id] },
      origin: 'facebook_lead_ads'
    ).call(match, lead_attrs, cf_values: cf_values, cf_consumed: cf_consumed)
  end

  def source_label(integration)
    ['Facebook Lead Ads', integration.page_name.presence].compact.join(': ')
  end

  def build_notes(raw, leadgen_id, form_id, answers)
    parts = ["Source: Facebook Lead Ad"]
    parts << "Form ID: #{form_id}" if form_id.present?
    parts << "Lead ID: #{leadgen_id}"
    parts << "Campaign: #{raw['campaign_name']}" if raw['campaign_name'].present?
    parts << "Ad: #{raw['ad_name']}" if raw['ad_name'].present?

    lines = answer_lines(answers)
    parts << "\nForm answers:\n#{lines.join("\n")}" if lines.any?
    parts.join("\n")
  end

  # "what_are_you_looking_for?" reads as "What are you looking for?".
  def answer_lines(answers)
    answers.filter_map do |question, value|
      value = value.join(', ') if value.is_a?(Array)
      next if value.blank?

      "#{question.to_s.tr('_', ' ').strip.capitalize}: #{value}"
    end
  end

  # The CRM's Notes tab reads the notes table, not the lead's notes column, so
  # the answers go there as well. Best effort: the lead already exists.
  def write_answers_note(lead, integration, answers)
    lines = answer_lines(answers)
    return if lines.empty?

    Note.create!(
      entity_type: 'lead',
      entity_id: lead.id.to_s,
      content: "Facebook form answers\n\n#{lines.join("\n")}",
      created_by_name: "System (#{source_label(integration)})"
    )
  rescue StandardError => e
    Rails.logger.error "[ProcessFacebookLeadJob] answers note failed for lead #{lead.id}: #{e.class}: #{e.message}"
  end
end
