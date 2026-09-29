# frozen_string_literal: true

module FacebookLeads
  # Turns one Meta Lead Ads lead (the Graph lead object: id, field_data,
  # campaign and ad names) into the attributes of a CRM lead for a connected
  # Page. Shared by the live webhook (ProcessFacebookLeadJob) and the history
  # import (FacebookLeads::Import), so a lead reads the same however it came in.
  class LeadBuilder
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

    # attrs:       the lead's attributes, ready for Lead.create!
    # answers:     question => answer, for notes and the absorber
    # cf_values:   custom field key => value
    # cf_consumed: the Facebook keys that filled a custom field
    Result = Struct.new(:attrs, :answers, :cf_values, :cf_consumed, keyword_init: true)

    def initialize(integration, company = nil)
      @integration = integration
      @company = company || Company.find(integration.company_id)
    end

    def build(raw, leadgen_id:, form_id: nil)
      parsed = parse_field_data(raw['field_data'] || [])
      attrs, answers, cf_values, cf_consumed = route_fields(parsed, @integration.field_mapping)
      first_name, last_name = split_name(attrs)

      # Every mapped column, not just the contact ones, so a question pointed at
      # Budget Range or Purchase Timeframe lands there.
      column_attrs = attrs.except('full_name', 'first_name', 'last_name')
                          .transform_values { |v| v.is_a?(Array) ? v.join(', ') : v }
                          .symbolize_keys

      lead_attrs = column_attrs.merge(
        company_id:  @integration.company_id,
        # A page with no location of its own still lands the lead somewhere a
        # rep works. See Company#inbound_lead_location.
        location_id: @integration.location_id || @company.inbound_lead_location&.id,
        facebook_leadgen_id: leadgen_id.to_s,
        first_name:  first_name,
        last_name:   last_name,
        status:      'new',
        source_id:   resolve_source_id,
        owner_id:    resolve_owner_id,
        utm_source:  'facebook',
        utm_medium:  'paid_ad',
        utm_campaign: raw['campaign_name'] || raw['campaign_id'],
        utm_content:  raw['ad_name']       || raw['ad_id'],
        social_intent: 'paid_ad',
        survey_answers: answers.presence,
        custom_field_values: cf_values.presence,
        origin:      Lead::ORIGIN_FACEBOOK,
        notes: notes(raw, leadgen_id, form_id, answers)
      ).compact

      Result.new(attrs: lead_attrs, answers: answers, cf_values: cf_values, cf_consumed: cf_consumed)
    end

    def notes(raw, leadgen_id, form_id, answers)
      parts = ["Source: Facebook Lead Ad"]
      parts << "Form ID: #{form_id}" if form_id.present?
      parts << "Lead ID: #{leadgen_id}"
      parts << "Campaign: #{raw['campaign_name']}" if raw['campaign_name'].present?
      parts << "Ad: #{raw['ad_name']}" if raw['ad_name'].present?

      lines = answer_lines(answers)
      parts << "\nForm answers:\n#{lines.join("\n")}" if lines.any?
      parts.join("\n")
    end

    # The CRM's Notes tab reads the notes table, not the lead's notes column, so
    # the answers go there as well. Best effort: the lead already exists.
    def write_answers_note(lead, answers)
      lines = answer_lines(answers)
      return if lines.empty?

      Note.create!(
        entity_type: 'lead',
        entity_id: lead.id.to_s,
        content: "Facebook form answers\n\n#{lines.join("\n")}",
        created_by_name: "System (#{source_label})"
      )
    rescue StandardError => e
      Rails.logger.error "[FacebookLeads::LeadBuilder] answers note failed for lead #{lead.id}: #{e.class}: #{e.message}"
    end

    def source_label
      ['Facebook Lead Ads', @integration.page_name.presence].compact.join(': ')
    end

    def identity_match(lead_attrs)
      return nil if lead_attrs[:email].blank? && lead_attrs[:phone].blank?

      IdentityResolver.new(@company, email: lead_attrs[:email], phone: lead_attrs[:phone]).resolve
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
    def route_fields(parsed, mapping)
      mapping = (mapping.presence || {}).transform_keys { |k| k.to_s.downcase }
      lead_cfs = @company.custom_fields.active.for_module('leads').to_a

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

    def resolve_source_id
      return @integration.default_source_id if @integration.default_source_id.present?

      source = Source.find_or_create_by!(company_id: @integration.company_id, name: 'Facebook') do |s|
        s.source_type = 'paid_ad'
        s.is_active   = true
      end
      @integration.update_column(:default_source_id, source.id)
      source.id
    end

    def resolve_owner_id
      return @integration.default_owner_id if @integration.default_owner_id.present?

      # Fallback: first company admin
      User.where(company_id: @integration.company_id, role: 'admin').order(:id).limit(1).pick(:id)
    end

    # "what_are_you_looking_for?" reads as "What are you looking for?".
    def answer_lines(answers)
      answers.filter_map do |question, value|
        value = value.join(', ') if value.is_a?(Array)
        next if value.blank?

        "#{question.to_s.tr('_', ' ').strip.capitalize}: #{value}"
      end
    end
  end
end
