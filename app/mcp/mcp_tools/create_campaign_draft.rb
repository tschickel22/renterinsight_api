# frozen_string_literal: true

module McpTools
  # Builds an email or text campaign and saves it as a DRAFT. A draft never
  # sends: the scheduler and the send job both require 'running', and only a
  # person pressing Start in DealerTide moves it there. There is no start,
  # schedule, send or test-send tool.
  class CreateCampaignDraft < Base
    tool_name 'create_campaign_draft'
    title 'Draft an email or text campaign'
    description 'Build an email or text campaign (audience, sender, one or more steps) and save it as a DRAFT. ' \
                'Nothing is sent: a person reviews it and presses Start in DealerTide. This connector cannot start, ' \
                'schedule, send or test-send campaigns. Audience rules use fields on the record (status, source_name, ' \
                'owner_name, city, state, created_at...) with operators such as equals, in, contains, ' \
                'days_since_greater_than, tags_include. Merge tags like {{first_name}} work in subjects and text. ' \
                'Never use em or en dashes in the copy.'
    input_schema(
      properties: {
        name: { type: 'string' },
        description: { type: 'string' },
        channel: { type: 'string', enum: Campaign::CHANNELS },
        sender: { type: 'string', enum: %w[me record_owner],
                  description: 'me: from the signed-in user. record_owner: each lead from their own rep. Default me.' },
        audience: {
          type: 'object',
          description: 'Who it goes to: {"record_type": "Lead", "rules": {"type": "and", "children": ' \
                       '[{"field": "status", "operator": "equals", "value": "new"}]}}. record_type is Lead, Contact or Account.'
        },
        steps: {
          type: 'array',
          description: 'In order. Email: {"subject", "preheader", "text", "button_label", "button_url", "wait_days"}. ' \
                       'Text: {"sms_text", "wait_days"}. wait_days counts from the previous step (0 for the first).',
          items: { type: 'object' }
        }
      },
      required: %w[name channel audience steps]
    )
    writes!

    def self.perform(ctx, name:, channel:, audience:, steps:, description: nil, sender: 'me')
      MarketingAccess.require_campaigns!(ctx, 'create')
      audience = audience.to_h.deep_stringify_keys
      record_type = audience['record_type'].to_s
      raise UserError, 'audience.record_type must be Lead, Contact or Account.' unless CampaignAudience::SOURCE_TYPES.include?(record_type)

      rules = audience['rules'].is_a?(Hash) ? audience['rules'] : {}
      steps = Array(steps).map { |s| s.to_h.deep_stringify_keys }
      raise UserError, 'Give at least one step.' if steps.empty?

      check_steps!(channel, steps)
      matches = audience_size!(ctx, record_type, rules, channel)

      campaign = nil
      Campaign.transaction do
        campaign = ctx.company.campaigns.create!(
          name: name.to_s.strip.first(200), description: description, channel: channel, status: 'draft',
          campaign_type: steps.size > 1 ? 'drip' : 'blast', audience_mode: 'dynamic',
          from_identity_type: sender == 'record_owner' ? 'Owner' : 'User',
          from_identity_id: sender == 'record_owner' ? nil : ctx.user.id,
          from_display_name: sender == 'record_owner' ? nil : ctx.user.full_name,
          created_by_user_id: ctx.user.id
        )
        steps.each_with_index { |step, i| campaign.campaign_steps.create!(step_attrs(channel, step, i)) }
        campaign.create_campaign_audience!(source_type: record_type, filter_tree: rules)
      end
      ctx.record_change(action: 'created', record: campaign, after: { status: 'draft' })

      warnings = []
      warnings << "The audience has no rules, so it is every #{record_type.downcase} in the account." if rules.blank?
      warnings << 'The audience matches nobody right now.' if matches.zero?

      Base::Result.new(payload: {
        draft: { id: "campaign:#{campaign.id}", name: campaign.name, status: 'draft', channel: channel,
                 steps: steps.size, audience_matches_now: matches, url: MarketingAccess.campaign_url(ctx, campaign) },
        warnings: warnings,
        next_step: MarketingAccess.campaign_activation_note(ctx, campaign)
      }, count: 1)
    end

    def self.check_steps!(channel, steps)
      steps.each_with_index do |s, i|
        if channel == 'sms'
          raise UserError, "Step #{i + 1} needs sms_text." if s['sms_text'].blank?
        elsif s['subject'].blank? || s['text'].blank?
          raise UserError, "Step #{i + 1} needs a subject and text."
        end
        WriteHelpers.no_dashes!(s.values_at('subject', 'preheader', 'text', 'button_label', 'sms_text'))
      end
    end

    def self.audience_size!(ctx, record_type, rules, channel)
      Audiences::FilterCompiler.new(company: ctx.company, source_type: record_type, filter_tree: rules, channel: channel).count
    rescue Audiences::FilterCompiler::CompilationError => e
      raise UserError, "The audience rules do not work: #{e.message}. Nothing was saved."
    end

    def self.step_attrs(channel, step, index)
      wait = step['wait_days'].to_f
      wait = 0 if index.zero? || wait.negative?
      base = { position: index, wait_days: wait, wait_hours: 0, channel: channel, is_active: true }
      return base.merge(sms_body: step['sms_text'].to_s) if channel == 'sms'

      blocks = [{ 'type' => 'branded_header' }, { 'type' => 'text', 'html' => paragraphs(step['text']) }]
      if step['button_label'].present? && step['button_url'].to_s.match?(%r{\Ahttps?://|\A\{\{})
        blocks << { 'type' => 'button', 'label' => step['button_label'].to_s, 'url' => step['button_url'].to_s, 'style' => 'primary' }
      end
      blocks << { 'type' => 'sender_cta', 'cta_text' => 'Questions? Reply or give me a call.' }
      base.merge(subject: step['subject'].to_s, preheader: step['preheader'].to_s.presence, body_blocks: blocks)
    end

    # Plain text in, safe HTML paragraphs out. Merge tags pass through.
    def self.paragraphs(text)
      text.to_s.split(/\n{2,}/).map(&:strip).reject(&:empty?).map do |para|
        "<p>#{ERB::Util.html_escape(para).gsub("\n", '<br>')}</p>"
      end.join
    end
  end
end
