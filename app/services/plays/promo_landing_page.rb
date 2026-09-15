# frozen_string_literal: true

module Plays
  # "Promo landing page": one page for one offer, with a form that files every
  # lead under its own source. An ad, a post or an email points at the page,
  # and the lead response play the dealer picks follows up.
  #
  # Built from the pieces the landing page builder already uses: the marketing
  # container, the landing page form and page-level publishing. Follow-up is
  # not rebuilt here. The page's source is added to the chosen lead response
  # play through that play's own customize, so the rule that a source starts
  # only one play is enforced in one place.
  class PromoLandingPage
    KEY = 'promo_landing_page'
    NAME = 'Promo landing page'
    DESCRIPTION = 'A page for one offer, with a form that files each lead under Promo landing page. ' \
                  'Point an ad, a post or an email at it, and the lead response play you choose follows up.'

    SOURCE_NAME = 'Promo landing page'
    MODULE_KEY = 'marketing.landing_pages'
    LAYOUT_ID = 'lp-offer-focus'
    HERO_IMAGE = 'https://renterinsight-website-assets-staging.s3.us-west-2.amazonaws.com/brand/homes/champion/exteriors-01a64a43259ce5f5.jpg'
    MAX_HIGHLIGHTS = 3
    NO_FOLLOW_UP = 'none'

    # The blocks this play writes. Anything else on the page was added in the
    # page editor and is left alone.
    OWNED_BLOCKS = %w[hero features contact cta].freeze
    # The words a dealer edits here. Presentation (image, overlay, height) is
    # set once at install and then belongs to the page editor.
    COPY_KEYS = {
      'hero' => %w[title subtitle ctaText],
      'features' => %w[features],
      'contact' => %w[title description intakeFormId],
      'cta' => %w[buttonText buttonLink]
    }.freeze

    LIMITS = { 'title' => 60, 'headline' => 90, 'subheadline' => 200, 'button_text' => 30,
               'form_title' => 60, 'form_description' => 200, 'phone' => 30 }.freeze

    STAGES = {
      'sent_form' => 'Sent the form',
      'in_follow_up' => 'In follow-up',
      'became_deal' => 'Became a deal'
    }.freeze
    PERIODS = Plays::Tracking::PERIODS

    class << self
      def kind
        'landing_page'
      end

      def hidden?
        false
      end

      def available?(company)
        ModuleAccessService.new(company).module_enabled?(MODULE_KEY)
      end

      def default_content
        {
          'title' => 'Special offer',
          'headline' => 'Save on a new home this month',
          'subheadline' => 'Tell us what you are looking for and we will send homes and pricing today.',
          'highlights' => ['Homes on our lot, ready to see', 'Help with financing', 'Delivery and setup handled for you'],
          'button_text' => 'Get details',
          'form_title' => 'Request details',
          'form_description' => 'Tell us how to reach you and we will follow up today.',
          'phone' => '',
          'publish' => true,
          'follow_up_play' => nil
        }
      end

      def normalize_content(raw)
        defaults = default_content
        given = (raw || {}).to_h.deep_stringify_keys
        merged = defaults.merge(given.slice(*defaults.keys))
        normalized = LIMITS.keys.to_h { |key| [key, merged[key].to_s.strip] }
        normalized.merge(
          'highlights' => Array(merged['highlights']).map { |h| h.to_s.strip }.reject(&:blank?).first(MAX_HIGHLIGHTS),
          'publish' => ActiveModel::Type::Boolean.new.cast(merged['publish']) || false,
          'follow_up_play' => merged['follow_up_play'].presence&.to_s
        )
      end

      # Lead response plays that are on, which the page's leads can go to.
      def follow_up_options(company)
        PlayInstallation.active.where(company_id: company.id).filter_map do |installation|
          play = Plays::Registry.find(installation.play_key)
          next unless play&.kind == 'lead_response'

          { key: play::KEY, name: play::NAME }
        end
      end

      # The play that follows up today: whichever lead response play starts
      # from this page's source, however the source got there.
      def follower_for(company)
        PlayInstallation.active.where(company_id: company.id).each do |installation|
          play = Plays::Registry.find(installation.play_key)
          next unless play&.kind == 'lead_response'
          return { key: play::KEY, name: play::NAME, installation: installation } if play.answers_for(installation)['sources'].include?(SOURCE_NAME)
        end
        nil
      end

      def definition(company)
        available = available?(company)
        content = normalize_content(nil).merge('phone' => company.inbound_lead_location&.phone.to_s)
        {
          key: KEY,
          name: NAME,
          description: DESCRIPTION,
          kind: kind,
          hidden: false,
          available: available,
          unavailable_reason: available ? nil : 'Landing pages are not part of your plan. Ask us to add them, or add Campaign Desk.',
          source: SOURCE_NAME,
          max_highlights: MAX_HIGHLIGHTS,
          limits: LIMITS,
          follow_up_options: follow_up_options(company),
          default_content: content,
          map: map_for(company: company, content: content, page: nil, follower: follower_for(company))
        }
      end

      # Other plays ask which lead sources a play claims. This one claims none:
      # its source belongs to whichever lead response play follows up.
      def answers_for(installation)
        { 'sources' => [], 'content' => normalize_content((installation.answers || {})['content']) }
      end

      def page_for(installation)
        WebsitePage.active.landing_pages
                   .where(website_id: Website.where(company_id: installation.company_id).select(:id))
                   .find_by(id: installation.asset_ids(:website_page_ids).first)
      end

      def form_for(installation)
        IntakeForm.find_by(company_id: installation.company_id, id: installation.asset_ids(:intake_form_ids).first)
      end

      def installation_json(installation)
        company = installation.company
        page = page_for(installation)
        form = form_for(installation)
        follower = follower_for(company)
        content = answers_for(installation)['content'].merge('follow_up_play' => follower ? follower[:key] : NO_FOLLOW_UP)
        {
          id: installation.id,
          status: installation.status,
          installed_at: installation.installed_at&.iso8601,
          updated_at: installation.updated_at&.iso8601,
          content: content,
          map: map_for(company: company, content: content, page: page, follower: follower),
          page: page && {
            id: page.id,
            title: page.title,
            path: page.path,
            public_url: LandingPages::PublicUrl.for(page),
            published: page.published?
          },
          intake_forms: form ? [{ id: form.id, name: form.name, source: form.source&.name, public_url: form.public_url,
                                  embed_code: form.embed_code, is_active: form.is_active }] : [],
          follow_up_play: follower&.slice(:key, :name)
        }
      end

      # The page comes down and its form stops taking submissions. The source
      # stays on the follow-up play: leads already carry it, and with the form
      # off no new ones arrive under it.
      def uninstall!(installation)
        ActiveRecord::Base.transaction do
          page_for(installation)&.unpublish!
          form_for(installation)&.update!(is_active: false)
          installation.update!(status: 'uninstalled', uninstalled_at: Time.current)
        end
        installation
      end

      # "Turn off and remove": the page is deleted outright, so it leaves Landing
      # Pages too. Its form, submissions and leads stay.
      def remove_built!(installation)
        page = page_for(installation)
        page&.update!(is_deleted: true, deleted_at: Time.current, published_at: nil, is_visible: false)
      end

      def map_for(company:, content:, page:, follower:)
        url = page && LandingPages::PublicUrl.for(page)
        location = company.inbound_lead_location
        [
          { key: 'trigger', kind: 'trigger', title: 'Someone opens the page',
            detail: url ? "From an ad, a post or an email that links to #{url}" : 'From an ad, a post or an email that links to it. The link appears once the play is on.' },
          { key: 'page', kind: 'page', title: content['headline'],
            condition: page_status(page, content),
            preview: [content['subheadline'], content['highlights'].map { |h| "✔ #{h}" }.join("\n")].reject(&:blank?).join("\n\n") },
          { key: 'form', kind: 'form', title: 'They send the form', subject: content['form_title'],
            preview: 'First name, last name, email and phone',
            detail: ["Filed under #{SOURCE_NAME}", location && "at #{location.name}"].compact.join(' ') },
          if follower
            { key: 'follow_up', kind: 'assign', title: "#{follower[:name]} follows up",
              detail: 'It assigns a rep, sends the first messages and starts the follow-up emails.' }
          else
            { key: 'follow_up', kind: 'end', title: 'No play follows up yet',
              detail: "Leads wait in your lead list. Choose a follow-up play, or add #{SOURCE_NAME} to a lead response play's sources." }
          end
        ]
      end

      # ── Results ──────────────────────────────────────────────────────────

      def performance_for(installation, period:, location_ids:)
        period = PERIODS.key?(period.to_s) ? period.to_s : Plays::Tracking::DEFAULT_PERIOD
        since = PERIODS[period]&.days&.ago
        rows = lead_rows(installation, location_ids, since: since)
        page = page_for(installation)
        visits = page ? PageVisit.real.where(website_page_id: page.id) : PageVisit.none
        visits = visits.where('first_seen_at >= ?', since) if since
        visitors = visits.distinct.count(:visitor_token)
        converted_visitors = visits.converted.distinct.count(:visitor_token)

        {
          period: period,
          stages: STAGES.map { |key, label| { key: key, label: label } },
          stage_counts: STAGES.keys.to_h { |stage| [stage, rows.count { |r| r[:stage] == stage }] },
          step_counts: {},
          metrics: {
            visits: visits.count,
            visitors: visitors,
            form_starts: PageVisitEvent.where(page_visit_id: visits.select(:id), event_type: 'form_start').distinct.count(:page_visit_id),
            leads: rows.size,
            conversion_rate: visitors.zero? ? nil : (converted_visitors.to_f / visitors).round(3),
            followed_up: rows.count { |r| r[:run_started_at] },
            deals: rows.count { |r| r[:stage] == 'became_deal' },
            published: page&.published? || false
          }
        }
      end

      def leads_for(installation, period:, location_ids:, stage:, page:, per_page:)
        period = PERIODS.key?(period.to_s) ? period.to_s : Plays::Tracking::DEFAULT_PERIOD
        rows = lead_rows(installation, location_ids, since: PERIODS[period]&.days&.ago)
        rows = rows.select { |r| r[:stage] == stage.to_s } if STAGES.key?(stage.to_s)
        per_page = per_page.to_i.clamp(1, 100)
        page = [page.to_i, 1].max
        total = rows.size

        {
          items: (rows.slice((page - 1) * per_page, per_page) || []).map { |row| row_json(row) },
          meta: { total: total, page: page, per_page: per_page, total_pages: (total.to_f / per_page).ceil }
        }
      end

      def lead_journey_for(installation, lead, location_ids:)
        row = lead_rows(installation, location_ids, lead_id: lead.id).first
        return nil unless row

        events = []
        page = page_for(installation)
        if page
          PageVisit.real.where(website_page_id: page.id, identified_entity_type: 'Lead', identified_entity_id: lead.id)
                   .order(:first_seen_at).each do |visit|
            events << { at: visit.first_seen_at&.iso8601, kind: 'visit', title: 'Opened the page',
                        detail: [visit.utm_source.presence && "From #{visit.utm_source}", visit.device_type.presence].compact.join(', ').presence }
          end
        end
        form = form_for(installation)
        IntakeSubmission.where(intake_form_id: form&.id, lead_id: lead.id).order(:created_at).each do |submission|
          events << { at: (submission.submitted_at || submission.created_at)&.iso8601, kind: 'form', title: 'Sent the form',
                      detail: form.name }
        end
        if row[:run_started_at]
          events << { at: row[:run_started_at].iso8601, kind: 'assign', title: "Started #{row[:play_name]}", detail: nil }
        end
        if lead.is_converted && lead.converted_at
          events << { at: lead.converted_at.iso8601, kind: 'deal', title: 'Became a deal', detail: nil }
        end

        # Stable, so a form and the run it started in the same second keep their order.
        ordered = events.each_with_index.sort_by { |event, index| [event[:at].to_s, index] }.map(&:first)
        { lead: row_json(row).merge(phone: lead.phone), events: ordered }
      end

      private

      def page_status(page, content)
        return(content['publish'] ? 'Published as soon as the play is on' : 'Saved as a draft until you publish it') unless page

        page.published? ? 'Published' : 'Not published, so visitors cannot open it'
      end

      # Each lead that sent this page's form, by its latest submission, newest
      # first, with where it is now.
      def lead_rows(installation, location_ids, since: nil, lead_id: nil)
        form = form_for(installation)
        return [] unless form

        submissions = IntakeSubmission.where(intake_form_id: form.id).where.not(lead_id: nil)
        submissions = submissions.where(lead_id: lead_id) if lead_id
        submissions = submissions.where('COALESCE(submitted_at, created_at) >= ?', since) if since
        latest = submissions.to_a.sort_by { |s| s.submitted_at || s.created_at }.reverse.uniq(&:lead_id)

        leads = Lead.where(company_id: installation.company_id, id: latest.map(&:lead_id))
        leads = leads.where(location_id: location_ids) if location_ids
        leads = leads.includes(:source, :owner).index_by(&:id)
        runs = follow_up_runs(installation.company_id, leads.keys)

        latest.filter_map do |submission|
          lead = leads[submission.lead_id]
          next unless lead

          sent_at = submission.submitted_at || submission.created_at
          # A run starts a moment after the lead is created from the form.
          run = runs[lead.id]&.find { |r| r[:started_at] && r[:started_at] >= sent_at - 5.minutes }
          stage = if lead.is_converted then 'became_deal'
                  elsif run then 'in_follow_up'
                  else 'sent_form'
                  end
          { lead: lead, sent_at: sent_at, stage: stage, run_started_at: run&.dig(:started_at), play_name: run&.dig(:play_name) }
        end
      end

      def follow_up_runs(company_id, lead_ids)
        return {} if lead_ids.empty?

        rule_plays = {}
        PlayInstallation.active.where(company_id: company_id).each do |installation|
          play = Plays::Registry.find(installation.play_key)
          next unless play&.kind == 'lead_response'

          installation.asset_ids(:workflow_rule_ids).each { |id| rule_plays[id.to_i] = play::NAME }
        end
        return {} if rule_plays.empty?

        WorkflowRun.where(company_id: company_id, entity_type: 'Lead', entity_id: lead_ids, workflow_rule_id: rule_plays.keys)
                   .order(:started_at)
                   .pluck(:entity_id, :workflow_rule_id, :started_at)
                   .group_by(&:first)
                   .transform_values { |list| list.map { |(_, rule_id, at)| { started_at: at, play_name: rule_plays[rule_id] } } }
      end

      def row_json(row)
        lead = row[:lead]
        detail, detail_at = case row[:stage]
                            when 'became_deal' then ['Converted to a deal', lead.converted_at]
                            when 'in_follow_up' then ["Followed up by #{row[:play_name]}, started", row[:run_started_at]]
                            else ['Sent the form. No play has followed up.', row[:sent_at]]
                            end
        {
          lead_id: lead.id,
          name: [lead.first_name, lead.last_name].compact.join(' ').strip.presence || lead.email || "Lead ##{lead.id}",
          email: lead.email,
          source: lead.source&.name,
          rep: lead.owner && LeadResponsePlay.display_name(lead.owner),
          started_at: row[:sent_at]&.iso8601,
          stage: row[:stage],
          stage_label: STAGES.fetch(row[:stage]),
          detail: detail,
          detail_at: detail_at&.iso8601
        }
      end
    end

    # ── Install and customize ────────────────────────────────────────────

    def initialize(company:, user:, answers:, installation: nil)
      @company = company
      @user = user
      @answers = (answers || {}).to_h.deep_stringify_keys
      @installation = installation
    end

    def install!
      if PlayInstallation.active.exists?(company_id: @company.id, play_key: KEY)
        raise InstallError, "#{NAME} is already on. Customize it instead."
      end
      validate!

      ActiveRecord::Base.transaction do
        location = @company.inbound_lead_location
        site = Marketing::MarketingSiteProvisioner.call(company: @company, location: location)
        source = @company.sources.find_or_create_by!(name: SOURCE_NAME) { |s| s.is_active = true }
        created_source_ids = source.previously_new_record? ? [source.id] : []
        form = Marketing::LandingPageFormBuilder.new(company: @company, title: content['title'], location: location,
                                                     notified_user: @user, source: source).call
        page = site.website_pages.create!(
          title: content['title'],
          path: unique_path(site),
          page_kind: 'landing',
          layout_id: LAYOUT_ID,
          intake_form: form,
          blocks: fresh_blocks(form),
          seo_title: content['headline'],
          seo_description: content['subheadline']
        )
        page.publish! if content['publish']
        sync_follow_up!

        PlayInstallation.create!(
          company_id: @company.id,
          play_key: KEY,
          status: 'active',
          answers: { content: content },
          assets: { website_page_ids: [page.id], intake_form_ids: [form.id], source_ids: created_source_ids },
          installed_by_user_id: @user&.id,
          installed_at: Time.current
        )
      end
    rescue Marketing::MarketingSiteProvisioner::ProvisioningError => e
      raise InstallError, "The page could not be created: #{e.message}"
    end

    # Rewrites this play's words on the page and keeps everything else: blocks
    # added in the page editor, and the image and layout chosen there.
    def customize!
      raise InstallError, "#{NAME} is not on." unless @installation&.status == 'active'
      validate!

      page = self.class.page_for(@installation)
      raise InstallError, 'The page for this play is missing. Turn the play off and on again.' unless page

      ActiveRecord::Base.transaction do
        page.update!(title: content['title'], blocks: merged_blocks(page.blocks, self.class.form_for(@installation)),
                     seo_title: content['headline'], seo_description: content['subheadline'])
        if content['publish'] && !page.published?
          page.publish!
        elsif !content['publish'] && page.published?
          page.unpublish!
        end
        sync_follow_up!
        @installation.update!(answers: { content: content.except('follow_up_play') })
      end
      @installation
    end

    private

    def content
      @content ||= self.class.normalize_content(@answers['content'])
    end

    def validate!
      unless self.class.available?(@company)
        raise InstallError, 'Landing pages are not part of your plan. Ask us to add them, or add Campaign Desk.'
      end
      raise InstallError, 'Add a location before turning this on.' unless @company.inbound_lead_location

      { 'title' => 'Name the page', 'headline' => 'Write a headline', 'form_title' => 'Give the form a title',
        'button_text' => 'Give the button a label' }.each do |key, message|
        raise InstallError, "#{message}." if content[key].blank?
      end
      LIMITS.each do |key, max|
        raise InstallError, "Keep the #{key.humanize(capitalize: false)} under #{max} characters." if content[key].length > max
      end
      if content['highlights'].any? { |h| h.length > 80 }
        raise InstallError, 'Keep each highlight under 80 characters.'
      end

      wanted = content['follow_up_play']
      return if wanted.nil? || wanted == NO_FOLLOW_UP
      return if self.class.follow_up_options(@company).any? { |option| option[:key] == wanted }

      raise InstallError, 'Choose a follow-up play that is on.'
    end

    # nil leaves follow-up as it is; 'none' takes the source off the play that
    # follows up; a play key moves the source to that play.
    def sync_follow_up!
      wanted = content['follow_up_play']
      return if wanted.nil?

      current = self.class.follower_for(@company)
      return if current && current[:key] == wanted

      move_source!(current, remove: true) if current
      return if wanted == NO_FOLLOW_UP

      installation = PlayInstallation.active.find_by(company_id: @company.id, play_key: wanted)
      move_source!({ key: wanted, name: Plays::Registry.find(wanted)::NAME, installation: installation }, remove: false)
    end

    def move_source!(target, remove:)
      play = Plays::Registry.find(target[:key])
      answers = play.answers_for(target[:installation])
      sources = remove ? answers['sources'] - [SOURCE_NAME] : (answers['sources'] + [SOURCE_NAME]).uniq
      if sources.empty?
        raise InstallError, "#{play::NAME} starts only from #{SOURCE_NAME}. Give it another source first, " \
                            'or it would have nothing to start from.'
      end

      play.new(company: @company, user: @user, installation: target[:installation],
               answers: answers.merge('sources' => sources)).customize!
    end

    def unique_path(site)
      base = "/#{content['title'].parameterize.presence || 'offer'}"
      taken = site.website_pages.where('path = ? OR path LIKE ?', base, "#{base}-%").pluck(:path)
      return base unless taken.include?(base)

      (2..500).each do |n|
        candidate = "#{base}-#{n}"
        return candidate unless taken.include?(candidate)
      end
      "#{base}-#{SecureRandom.hex(3)}"
    end

    def fresh_blocks(form)
      blocks = [
        { 'type' => 'hero', 'content' => block_copy('hero', form).merge(
          'backgroundImage' => HERO_IMAGE, 'overlayOpacity' => 55, 'ctaLink' => '#contact',
          'height' => 'large', 'alignment' => 'center'
        ) }
      ]
      blocks << { 'type' => 'features', 'content' => block_copy('features', form).merge('title' => 'What you get') } if content['highlights'].any?
      blocks << { 'type' => 'contact', 'content' => block_copy('contact', form) }
      if content['phone'].present?
        blocks << { 'type' => 'cta', 'content' => block_copy('cta', form).merge(
          'title' => 'Prefer to talk?', 'subtitle' => 'Call us and we will walk you through it.'
        ) }
      end
      blocks.each_with_index.map { |block, index| block.merge('id' => "block_#{SecureRandom.hex(6)}", 'order' => index) }
    end

    # Copy on the existing blocks is replaced; a block this play owns that is
    # no longer wanted (highlights cleared, phone removed) comes off; one newly
    # wanted is added where it belongs.
    def merged_blocks(existing, form)
      fresh = fresh_blocks(form).index_by { |block| block['type'] }
      seen = []
      blocks = Array(existing).filter_map do |block|
        type = block['type'].to_s
        next block unless OWNED_BLOCKS.include?(type) && !seen.include?(type)

        seen << type
        next nil unless fresh[type]

        block.merge('content' => (block['content'].is_a?(Hash) ? block['content'] : {}).merge(block_copy(type, form)))
      end

      (fresh.keys - seen).each do |type|
        if type == 'features'
          contact_at = blocks.index { |b| b['type'].to_s == 'contact' } || blocks.size
          blocks.insert(contact_at, fresh[type])
        elsif type == 'hero'
          blocks.unshift(fresh[type])
        else
          blocks << fresh[type]
        end
      end
      blocks.each_with_index.map { |block, index| block.merge('order' => index) }
    end

    def block_copy(type, form)
      case type
      when 'hero'
        { 'title' => content['headline'], 'subtitle' => content['subheadline'], 'ctaText' => content['button_text'] }
      when 'features'
        { 'features' => content['highlights'].map { |h| { 'icon' => '✔', 'title' => h, 'description' => '' } } }
      when 'contact'
        { 'title' => content['form_title'], 'description' => content['form_description'], 'intakeFormId' => form&.id }
      when 'cta'
        { 'buttonText' => "Call #{content['phone']}", 'buttonLink' => "tel:#{content['phone'].gsub(/[^\d+]/, '')}" }
      end.slice(*COPY_KEYS.fetch(type))
    end
  end
end
