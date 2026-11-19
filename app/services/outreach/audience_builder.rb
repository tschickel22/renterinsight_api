# frozen_string_literal: true

module Outreach
  # Turns a plain description into a wave (backlog E105): AI writes the filter,
  # the eligibility rules are always applied on top, AI ranks who looks most
  # worth a demo, and the best group is split at random into contacted and held
  # back so the comparison between them stays fair.
  class AudienceBuilder
    MAX_CANDIDATES = 120
    REQUIRED_FILTER = { 'field' => 'custom:category', 'operator' => 'equals', 'value' => 'MH Retailer' }.freeze
    # Engagement and "if possible" wishes decide the ranking, not who is allowed in.
    FILTER_NOTE = 'Filter only on facts a lead record must have, using values that exist in the context. Leave out wishes about ' \
                  'opened or clicked emails, number of locations, and anything described as preferred or "if possible": ' \
                  'they are used later to rank the matches, so filtering on them would wrongly shut leads out.'

    RANK_TOOL = {
      name: 'rank_leads',
      description: 'Return the leads most worth contacting, best first.',
      input_schema: {
        type: 'object',
        properties: {
          picks: { type: 'array', items: { type: 'object', properties: {
            id: { type: 'integer' }, reason: { type: 'string', description: 'Under 15 words, from the facts given.' }
          }, required: %w[id reason] } }
        },
        required: %w[picks]
      }
    }.freeze

    def initialize(wave, user: nil)
      @wave = wave
      @company = wave.company
      @user = user
      @eligibility = Eligibility.new(@company)
    end

    def call
      tree = filter_tree
      leads = candidates(tree)
      @wave.update!(filter_tree: tree, eligible_count: leads.size)
      raise AiClient::Error, empty_message(tree) if leads.empty?

      picks = ranked(leads).first(@wave.target_size * 2)
      save_targets(picks)
      @wave.update!(status: 'audience_ready', build_error: nil)
    end

    private

    def filter_tree
      described = if @wave.prompt.present?
                    generated = Audiences::AiBuilder.new(company: @company, user: @user)
                                                    .generate(prompt: "#{@wave.prompt}\n\n#{FILTER_NOTE}", source_type: 'Lead').generated_filter_tree
                    prune(generated) || { 'type' => 'and', 'children' => [] }
                  else
                    { 'type' => 'and', 'children' => [] }
                  end
      return described unless StarterContent.available_for?(@company)

      { 'type' => 'and', 'children' => [REQUIRED_FILTER, described] }
    end

    # The AI sometimes names a tag or source the company has never used. A rule
    # no lead could pass would empty the whole audience, so it is dropped.
    def prune(node)
      return nil unless node.is_a?(Hash)

      if node['children'].is_a?(Array)
        children = node['children'].filter_map { |child| prune(child) }
        return nil if children.empty?

        return node.merge('children' => children)
      end

      any_lead_passes?(node) ? node : nil
    end

    def any_lead_passes?(leaf)
      Audiences::FilterCompiler.new(company: @company, source_type: 'Lead', filter_tree: { 'type' => 'and', 'children' => [leaf] }).scope.exists?
    rescue StandardError => e
      Rails.logger.info("[Outreach::AudienceBuilder] dropped rule #{leaf.to_json}: #{e.class}")
      false
    end

    def matching_scope(tree)
      Audiences::FilterCompiler.new(company: @company, source_type: 'Lead', filter_tree: tree).scope
    end

    def empty_message(tree)
      described = matching_scope(tree).count
      return 'No leads match that description' if described.zero?

      "#{described} #{'lead'.pluralize(described)} match that description, but none can be contacted now: each is already being " \
        'worked (not New, no owner, on a campaign, nurture or workflow, in a conversation, or active in the last 30 days), ' \
        'or has no usable email and no text consent'
    end

    def candidates(tree)
      matching = Audiences::FilterCompiler.new(company: @company, source_type: 'Lead', filter_tree: tree,
                                               exclude_active_campaign_enrollees: true, exclude_active_nurture_enrollees: true,
                                               channel: 'mixed', sms_consent_acknowledged: true).scope
      @eligibility.scope.where(id: matching.select(:id)).includes(:source).limit(1000).to_a.select { |lead| @eligibility.reach(lead).any? }
    end

    # Engaged leads first, so the AI sees the most promising when there are many.
    def ranked(leads)
      activity = engagement(leads.map(&:id))
      ordered = leads.sort_by { |lead| [-activity.dig(lead.id, :clicks).to_i, -activity.dig(lead.id, :opens).to_i, lead.id] }
      pool = ordered.first(MAX_CANDIDATES)
      by_id = pool.index_by(&:id)
      chosen = ai_picks(pool, activity).filter_map { |pick| by_id[pick['id'].to_i] && [by_id[pick['id'].to_i], pick['reason']] }.uniq { |lead, _| lead.id }
      rest = ordered.reject { |lead| chosen.any? { |picked, _| picked.id == lead.id } }.map { |lead| [lead, fallback_reason(activity[lead.id])] }
      chosen + rest
    end

    def ai_picks(pool, activity)
      lines = pool.map { |lead| summary(lead, activity[lead.id]) }
      input = AiClient.call(
        company: @company, feature: 'audience_rank', tool: RANK_TOOL, max_tokens: 4000,
        system: "You choose which sales leads are most worth inviting to a software demo for #{@company.name}. Prefer leads who engaged " \
                'with past emails, visited the booth, have several locations, or name a competitor. Judge only from the facts given. ' \
                'Never use a person\'s name, gender, age or any personal trait. Do not use dashes.',
        user: "What we are looking for: #{@wave.prompt.presence || 'the best prospects'}\nReturn up to #{@wave.target_size * 2} leads.\n\n#{lines.join("\n")}"
      )
      Array(input['picks']).select { |pick| pick.is_a?(Hash) }
    rescue StandardError => e
      Rails.logger.warn("[Outreach::AudienceBuilder] ranking fell back to engagement: #{e.class}: #{e.message}")
      []
    end

    def summary(lead, activity)
      custom = lead.custom_field_values.to_h
      facts = { id: lead.id, company: lead.company_name, state: lead.state, source: lead.source&.name,
                visited_booth: custom['visited_booth'], locations: custom['number_of_dealership_locations'],
                competitor: custom['competition'], website: custom['website'].present?,
                opens: activity&.dig(:opens).to_i, clicks: activity&.dig(:clicks).to_i }
      facts.compact_blank.to_json
    end

    def fallback_reason(activity)
      return 'Clicked a past campaign link' if activity&.dig(:clicks).to_i.positive?
      return 'Opened past campaign emails' if activity&.dig(:opens).to_i.positive?

      'Matches the audience you described'
    end

    def engagement(ids)
      rows = CampaignSend.joins(:campaign_enrollment)
                         .where(company_id: @company.id, campaign_enrollments: { recipient_type: 'Lead', recipient_id: ids })
                         .group('campaign_enrollments.recipient_id')
                         .pluck(Arel.sql('campaign_enrollments.recipient_id'), Arel.sql('COUNT(campaign_sends.opened_at)'), Arel.sql('COUNT(campaign_sends.clicked_at)'))
      rows.to_h { |id, opens, clicks| [id, { opens: opens, clicks: clicks }] }
    end

    # Half of the chosen group at random is held back, up to the wave's size.
    def save_targets(picks)
      shuffled = picks.shuffle
      contact_count = [@wave.target_size, (shuffled.size / 2.0).ceil].min
      OutreachTarget.transaction do
        @wave.outreach_targets.delete_all
        shuffled.each_with_index do |(lead, reason), index|
          reach = @eligibility.reach(lead)
          @wave.outreach_targets.create!(
            company_id: @company.id, lead_id: lead.id, rank: index + 1, ai_reason: Assistant::Rules.tidy(reason).truncate(160),
            test_group: index < contact_count ? 'contact' : 'holdout', channel: reach.text ? 'text' : 'email'
          )
        end
      end
    end
  end
end
