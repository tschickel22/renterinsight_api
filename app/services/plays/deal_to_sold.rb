# frozen_string_literal: true

module Plays
  # "Deal to sold": what happens around a deal once it is moving.
  #
  # Rules listen to the dealer's own pipeline. Nothing here adds a stage or
  # assumes one; won and lost are whatever the dealer's pipeline says they are.
  #   won:    a thank-you, a check-in call for the rep, a review request and a
  #           referral ask, each some days after the win
  #   stages: a task for the rep when a deal reaches a stage the dealer picks
  #   lost:   a reminder for the rep to check back
  #
  # Buyer emails go to the deal's contact, from the rep. A deal whose contact
  # has no email skips them, because the send step would otherwise fall back to
  # the rep's own address. The rep's tasks still happen.
  class DealToSold
    KEY = 'deal_to_sold'
    NAME = 'Deal to sold'
    DESCRIPTION = 'When a deal is won, the buyer gets a thank-you, a review request and a referral ask from their rep, ' \
                  'and the rep gets a check-in call. Reps also get a task when a deal reaches a stage you choose, ' \
                  'and a reminder to check back on lost deals.'

    DONE_TAG = 'after-sale-done'
    MAX_STAGE_TASKS = 6
    MAX_DAYS = 365
    MAX_TASK_DUE_DAYS = 30

    EMAIL_FIELDS = {
      'first_name' => '{{entity.contact_first_name}}',
      'buyer_name' => '{{contact.full_name}}',
      'rep_name' => '{{entity.owner_name}}',
      'rep_phone' => '{{entity.owner_phone}}',
      'rep_email' => '{{entity.owner_email}}',
      'dealership' => :dealership
    }.freeze
    TASK_FIELDS = {
      'buyer_name' => '{{contact.full_name}}',
      'deal_name' => '{{entity.name}}'
    }.freeze
    SAMPLE_VALUES = {
      'first_name' => 'Tia', 'buyer_name' => 'Tia May', 'deal_name' => 'Tia May, Tru Buttercup',
      'rep_name' => 'Rita Rep', 'rep_phone' => '(303) 555-0142', 'rep_email' => 'rita@yourdealership.com'
    }.freeze
    FIELD_PATTERN = LeadResponsePlay::FIELD_PATTERN

    # The touches after a win, each some days after it.
    AFTER_SALE = {
      'thank_you' => { type: :email, title: 'Thank-you email' },
      'check_in' => { type: :task, title: 'Check-in call for the rep' },
      'review_request' => { type: :email, title: 'Review request' },
      'referral_ask' => { type: :email, title: 'Referral ask' }
    }.freeze

    STAGES = {
      'in_pipeline' => 'Stage task given',
      'after_sale' => 'In after-sale follow-up',
      'after_sale_done' => 'After-sale finished',
      'lost' => 'Lost, check-back set',
      'stopped' => 'Stopped'
    }.freeze
    PERIODS = Plays::Tracking::PERIODS

    class << self
      def kind
        'deal_followup'
      end

      def hidden?
        false
      end

      def default_content
        {
          'thank_you' => {
            'enabled' => true, 'day' => 0, 'subject' => 'Thank you, {{first_name}}',
            'body' => "Hi {{first_name}},\n\nThank you for choosing {{dealership}}. It was a pleasure working with you, " \
                      "and I am here for anything you need while we get your home ready.\n\n{{rep_name}}\n{{rep_phone}}"
          },
          'check_in' => { 'enabled' => true, 'day' => 7, 'subject' => 'Check in with {{buyer_name}}' },
          'review_request' => {
            'enabled' => false, 'day' => 30, 'subject' => 'How did we do, {{first_name}}?',
            'body' => "Hi {{first_name}},\n\nIf you have a minute, a short review helps other families find us. " \
                      "Thank you for trusting {{dealership}}.\n\n{{rep_name}}",
            'review_link' => ''
          },
          'referral_ask' => {
            'enabled' => true, 'day' => 60, 'subject' => 'Know someone looking for a home?',
            'body' => "Hi {{first_name}},\n\nI hope you are settling in well. If a friend or family member is looking " \
                      "for a home, reply with their name and I will take good care of them.\n\n{{rep_name}}"
          },
          'stage_tasks' => [],
          'lost_check_in' => { 'enabled' => true, 'days' => 30, 'subject' => 'Check back with {{buyer_name}}' }
        }
      end

      def normalize_content(raw)
        defaults = default_content
        given = (raw || {}).to_h.deep_stringify_keys
        content = {}

        AFTER_SALE.each_key do |key|
          base = defaults[key]
          merged = base.merge((given[key].is_a?(Hash) ? given[key] : {}).slice(*base.keys))
          content[key] = base.keys.to_h do |field|
            value = case field
                    when 'enabled' then cast_bool(merged[field])
                    when 'day' then merged[field].to_i
                    else merged[field].to_s.strip
                    end
            [field, value]
          end
        end

        tasks = given.key?('stage_tasks') ? given['stage_tasks'] : defaults['stage_tasks']
        tasks = tasks.values if tasks.is_a?(Hash)
        content['stage_tasks'] = Array(tasks).select { |task| task.is_a?(Hash) }.first(MAX_STAGE_TASKS).map do |task|
          { 'stage' => task['stage'].to_s.strip.downcase, 'subject' => task['subject'].to_s.strip, 'due_days' => task['due_days'].to_i }
        end

        lost = defaults['lost_check_in'].merge((given['lost_check_in'].is_a?(Hash) ? given['lost_check_in'] : {}).slice('enabled', 'days', 'subject'))
        content['lost_check_in'] = { 'enabled' => cast_bool(lost['enabled']), 'days' => lost['days'].to_i, 'subject' => lost['subject'].to_s.strip }
        content
      end

      def validate_content!(content, company)
        AFTER_SALE.each do |key, info|
          item = content[key]
          next unless item['enabled']

          label = info[:title].downcase
          raise InstallError, "Give the #{label} a #{info[:type] == :email ? 'subject' : 'title'}." if item['subject'].blank?
          raise InstallError, "Write the #{label}, or turn it off." if info[:type] == :email && item['body'].blank?
          unless (0..MAX_DAYS).cover?(item['day'])
            raise InstallError, "Send the #{label} between day 0 and day #{MAX_DAYS} after the win."
          end

          if info[:type] == :email
            check_fields!(item['subject'], EMAIL_FIELDS, "the #{label}")
            check_fields!(item['body'], EMAIL_FIELDS, "the #{label}")
          else
            check_fields!(item['subject'], TASK_FIELDS, "the #{label}")
          end
        end

        if content['review_request']['enabled'] && !content['review_request']['review_link'].match?(%r{\Ahttps?://\S+\z})
          raise InstallError, 'Add the link where buyers leave a review, starting with https://, or turn the review request off.'
        end

        options = stage_options(company).map { |stage| stage[:key] }
        seen = []
        content['stage_tasks'].each do |task|
          unless options.include?(task['stage'])
            raise InstallError, 'Choose a stage from your pipeline for each stage task. Won and lost have their own sections.'
          end
          raise InstallError, 'Each stage can have one task.' if seen.include?(task['stage'])

          seen << task['stage']
          raise InstallError, 'Give each stage task a title.' if task['subject'].blank?
          raise InstallError, "Make each stage task due within #{MAX_TASK_DUE_DAYS} days." unless (0..MAX_TASK_DUE_DAYS).cover?(task['due_days'])

          check_fields!(task['subject'], TASK_FIELDS, 'a stage task')
        end

        lost = content['lost_check_in']
        if lost['enabled']
          raise InstallError, 'Give the lost deal check-back a title.' if lost['subject'].blank?
          raise InstallError, "Set the check-back between 1 and #{MAX_DAYS} days after a loss." unless (1..MAX_DAYS).cover?(lost['days'])

          check_fields!(lost['subject'], TASK_FIELDS, 'the lost deal check-back')
        end

        return if after_sale_items(content).any? || content['stage_tasks'].any? || lost['enabled']

        raise InstallError, 'Turn on at least one part of the play.'
      end

      # The stages a task can be given for: the dealer's pipeline without its
      # won and lost stages, which have their own sections.
      def stage_options(company)
        closed = company.closed_deal_stage_keys
        company.pipeline_stages.filter_map do |stage|
          key = (stage['key'] || stage[:key]).to_s.downcase
          next if key.blank? || closed.include?(key)

          { key: key, label: stage_name(stage, key) }
        end
      end

      def stage_label(company, key)
        stage = company.pipeline_stages.find { |s| (s['key'] || s[:key]).to_s.downcase == key.to_s.downcase }
        stage ? stage_name(stage, key) : key.to_s.humanize
      end

      def after_sale_items(content)
        AFTER_SALE.keys.each_with_index
                  .select { |key, _| content[key]['enabled'] }
                  .sort_by { |key, index| [content[key]['day'], index] }
                  .map { |key, _| { key: key, day: content[key]['day'] } }
      end

      def definition(company)
        content = normalize_content(nil)
        {
          key: KEY,
          name: NAME,
          description: DESCRIPTION,
          kind: kind,
          hidden: false,
          fields: { emails: EMAIL_FIELDS.keys, tasks: TASK_FIELDS.keys },
          stage_options: stage_options(company),
          won_stages: won_stage_names(company),
          max_stage_tasks: MAX_STAGE_TASKS,
          default_content: content,
          map: map_for(company: company, content: content)
        }
      end

      def answers_for(installation)
        { 'sources' => [], 'content' => normalize_content((installation.answers || {})['content']) }
      end

      def rule_ids(installation, group)
        Array((installation.assets || {}).deep_stringify_keys["#{group}_rule_ids"]).map(&:to_i)
      end

      def installation_json(installation)
        company = installation.company
        content = answers_for(installation)['content']
        {
          id: installation.id,
          status: installation.status,
          installed_at: installation.installed_at&.iso8601,
          updated_at: installation.updated_at&.iso8601,
          content: content,
          map: map_for(company: company, content: content),
          workflow_rules: WorkflowRule.where(company_id: company.id, id: installation.asset_ids(:workflow_rule_ids))
                                      .where.not(status: 'archived')
                                      .map { |rule| { id: rule.id, name: rule.name, status: rule.status } }
        }
      end

      # Rules are archived and runs still waiting are cancelled, so no buyer
      # email goes out after the dealer said stop. Tasks already given stay.
      def uninstall!(installation)
        ActiveRecord::Base.transaction do
          WorkflowRule.where(company_id: installation.company_id, id: installation.asset_ids(:workflow_rule_ids)).find_each do |rule|
            archive_rule!(rule)
          end
          installation.update!(status: 'uninstalled', uninstalled_at: Time.current)
        end
        installation
      end

      def archive_rule!(rule)
        rule.update!(status: 'archived') unless rule.status == 'archived'
        WorkflowRun.where(workflow_rule_id: rule.id, status: %w[pending running waiting]).find_each do |run|
          WorkflowEngine.cancel(run, reason: 'play_turned_off')
        end
      end

      def map_for(company:, content:)
        after_sale = after_sale_items(content).map do |item|
          key = item[:key]
          settings = content[key]
          timing = item[:day].zero? ? 'Right away' : "Day #{item[:day]} after the win"
          if AFTER_SALE[key][:type] == :email
            preview = sample(company, settings['body'])
            preview += "\n\n[Link: Leave a review]" if key == 'review_request'
            { key: key, kind: 'email', title: AFTER_SALE[key][:title], timing: timing,
              condition: 'Only if the buyer has an email address', subject: sample(company, settings['subject']), preview: preview }
          else
            { key: key, kind: 'task', title: sample(company, settings['subject']), timing: timing,
              detail: "A call task for the deal's rep, due the next day." }
          end
        end
        after_sale = [{ key: 'no_after_sale', kind: 'end', title: 'Nothing after a win' }] if after_sale.empty?

        stage_steps = content['stage_tasks'].each_with_index.map do |task, index|
          { key: "stage_task_#{index + 1}", kind: 'task', title: sample(company, task['subject']),
            timing: "Reaches #{stage_label(company, task['stage'])}", detail: due_phrase(task['due_days']) }
        end
        stage_steps = [{ key: 'no_stage_tasks', kind: 'end', title: 'No stage tasks yet' }] if stage_steps.empty?

        lost = content['lost_check_in']
        lost_steps = if lost['enabled']
                       [{ key: 'lost_check_in', kind: 'task', title: sample(company, lost['subject']),
                          detail: "A task for the rep, due #{lost['days']} days after the loss." }]
                     else
                       [{ key: 'no_lost_check_in', kind: 'end', title: 'Nothing when a deal is lost' }]
                     end

        [
          { key: 'trigger', kind: 'trigger', title: 'A deal moves in your pipeline',
            detail: 'Uses your own stages. Nothing is added to your pipeline.',
            branches: [
              { key: 'won', label: "Won (#{won_stage_names(company).join(', ')})",
                note: "Emails come from the deal's rep and go to the deal's contact.", steps: after_sale },
              { key: 'stages', label: 'Reaches a stage you chose', steps: stage_steps },
              { key: 'lost', label: 'Lost', steps: lost_steps }
            ] }
        ]
      end

      # ── Results ──────────────────────────────────────────────────────────

      def performance_for(installation, period:, location_ids:)
        period = PERIODS.key?(period.to_s) ? period.to_s : Plays::Tracking::DEFAULT_PERIOD
        since = PERIODS[period]&.days&.ago
        runs = play_runs(installation, location_ids, since: since)
        rows = deal_rows(installation, runs)
        groups = rule_groups(installation)
        steps = step_rows(runs.map(&:id), groups)
        activity_ids = steps.filter_map { |row| row[:output]['id'] if row[:step_type] == 'create_activity' && row[:status] == 'success' }
        done_ids = DealActivity.where(id: activity_ids).where("status = 'completed' OR completed_at IS NOT NULL").pluck(:id)
        sent = ->(key) { steps.count { |row| row[:step_id] == key && row[:status] == 'success' } }
        tasks_for = lambda do |group|
          ids = steps.filter_map { |row| row[:output]['id'] if row[:rule_group] == group && row[:step_type] == 'create_activity' && row[:status] == 'success' }
          [ids.size, (ids & done_ids).size]
        end
        check_ins, check_ins_done = tasks_for.call(:won)
        stage_tasks, stage_tasks_done = tasks_for.call(:stage)
        lost_tasks, lost_tasks_done = tasks_for.call(:lost)
        won_runs = runs.select { |run| groups[run.workflow_rule_id] == :won }
        no_email = steps.select { |row| row[:step_id].start_with?('has_email_') && row[:output]['branch_taken'] == 'false' }
                        .map { |row| row[:run_id] }.uniq.size

        {
          period: period,
          stages: STAGES.map { |key, label| { key: key, label: label } },
          stage_counts: STAGES.keys.to_h { |stage| [stage, rows.count { |r| r[:stage] == stage }] },
          step_counts: step_counts(rows),
          metrics: {
            deals_won: won_runs.map(&:entity_id).uniq.size,
            thank_yous_sent: sent.call('thank_you'),
            review_requests_sent: sent.call('review_request'),
            referral_asks_sent: sent.call('referral_ask'),
            won_without_email: no_email,
            check_ins: check_ins,
            check_ins_done: check_ins_done,
            stage_tasks: stage_tasks,
            stage_tasks_done: stage_tasks_done,
            lost_check_ins: lost_tasks,
            lost_check_ins_done: lost_tasks_done
          }
        }
      end

      def leads_for(installation, period:, location_ids:, stage:, page:, per_page:)
        period = PERIODS.key?(period.to_s) ? period.to_s : Plays::Tracking::DEFAULT_PERIOD
        runs = play_runs(installation, location_ids, since: PERIODS[period]&.days&.ago)
        rows = deal_rows(installation, runs)
        rows = rows.select { |r| r[:stage] == stage.to_s } if STAGES.key?(stage.to_s)
        per_page = per_page.to_i.clamp(1, 100)
        page = [page.to_i, 1].max
        total = rows.size

        {
          items: (rows.slice((page - 1) * per_page, per_page) || []).map { |row| row_json(installation, row) },
          meta: { total: total, page: page, per_page: per_page, total_pages: (total.to_f / per_page).ceil }
        }
      end

      # The journey endpoint looks up this play's record by id: a deal.
      def journey_record(company, id)
        Deal.where(company_id: company.id).find_by(id: id)
      end

      def lead_journey_for(installation, deal, location_ids:)
        return nil if location_ids && !location_ids.map(&:to_i).include?(deal.location_id)

        runs = play_runs(installation, nil, deal_id: deal.id).sort_by { |run| [run.started_at || run.created_at, run.id] }
        return nil if runs.empty?

        company = installation.company
        groups = rule_groups(installation)
        stage_of_rule = stage_rule_map(installation).invert
        steps = step_rows(runs.map(&:id)).group_by { |row| row[:run_id] }
        activities = DealActivity.where(deal_id: deal.id).index_by(&:id)
        events = []

        runs.each do |run|
          at = (run.started_at || run.created_at)&.iso8601
          case groups[run.workflow_rule_id]
          when :won then events << { at: at, kind: 'deal', title: 'Deal won', detail: nil }
          when :lost then events << { at: at, kind: 'stopped', title: 'Deal lost', detail: nil }
          else
            stage = stage_of_rule[run.workflow_rule_id]
            events << { at: at, kind: 'trigger', title: "Reached #{stage ? stage_label(company, stage) : 'a stage'}", detail: nil }
          end

          skipped = false
          Array(steps[run.id]).each do |row|
            step_at = row[:at]&.iso8601
            if row[:step_type] == 'send_email' && row[:status] == 'success'
              events << { at: step_at, kind: 'email', title: "#{AFTER_SALE.dig(row[:step_id], :title) || 'Email'} sent", detail: row[:output]['to'] }
            elsif row[:step_id].start_with?('has_email_') && row[:output]['branch_taken'] == 'false' && !skipped
              skipped = true
              events << { at: step_at, kind: 'skipped', title: 'No buyer email address, so buyer emails were skipped', detail: nil }
            elsif row[:step_type] == 'create_activity' && row[:status] == 'success'
              activity = activities[row[:output]['id'].to_i]
              events << { at: step_at, kind: 'task', title: "Task for the rep: #{activity&.subject || 'follow up'}", detail: nil }
              if activity && (activity.status == 'completed' || activity.completed_at)
                events << { at: (activity.completed_at || activity.updated_at)&.iso8601, kind: 'task_done', title: 'Task completed', detail: nil }
              end
            elsif row[:status] == 'failed'
              events << { at: step_at, kind: 'stopped', title: 'A step failed', detail: row[:error]['message'] }
            end
          end

          if run.status == 'waiting' && run.wait_until
            next_key = run.current_step_id.to_s.delete_prefix('has_email_')
            events << { at: nil, kind: 'wait', title: "Next: #{AFTER_SALE.dig(next_key, :title) || 'the next step'}",
                        detail: "On #{run.wait_until.iso8601}" }
          end
        end

        row = deal_rows(installation, runs).first
        dated, undated = events.each_with_index.partition { |event, _| event[:at] }
        ordered = dated.sort_by { |event, index| [event[:at], index] }.map(&:first) + undated.map(&:first)
        { lead: row_json(installation, row).merge(phone: deal.contact&.phone), events: ordered }
      end

      private

      def cast_bool(value)
        ActiveModel::Type::Boolean.new.cast(value) || false
      end

      def check_fields!(text, allowed, where)
        unknown = text.to_s.scan(FIELD_PATTERN).flatten.uniq - allowed.keys
        return if unknown.empty?

        raise InstallError, "#{unknown.map { |f| "{{#{f}}}" }.join(', ')} can't be used in #{where}. " \
                            "Available: #{allowed.keys.map { |f| "{{#{f}}}" }.join(', ')}."
      end

      def sample(company, text)
        text.to_s.gsub(FIELD_PATTERN) do
          field = Regexp.last_match(1)
          field == 'dealership' ? company.name : SAMPLE_VALUES.fetch(field, Regexp.last_match(0))
        end
      end

      def stage_name(stage, key)
        (stage['name'] || stage[:name] || stage['label'] || stage[:label]).presence || key.to_s.humanize
      end

      def won_stage_names(company)
        names = company.won_stage_keys.filter_map do |key|
          stage = company.pipeline_stages.find { |s| (s['key'] || s[:key]).to_s.downcase == key }
          stage && stage_name(stage, key)
        end
        names.presence || ['Closed Won']
      end

      def due_phrase(days)
        return 'Due the same day.' if days.zero?

        "Due in #{days} #{days == 1 ? 'day' : 'days'}."
      end

      def stage_rule_map(installation)
        ((installation.assets || {}).deep_stringify_keys.dig('rules', 'stages') || {}).transform_values(&:to_i)
      end

      # rule id => :won, :lost or :stage, for every rule the play ever made.
      def rule_groups(installation)
        groups = {}
        rule_ids(installation, 'won').each { |id| groups[id] = :won }
        rule_ids(installation, 'lost').each { |id| groups[id] = :lost }
        rule_ids(installation, 'stage').each { |id| groups[id] = :stage }
        groups
      end

      def play_runs(installation, location_ids, since: nil, deal_id: nil)
        scope = WorkflowRun.where(company_id: installation.company_id, entity_type: 'Deal',
                                  workflow_rule_id: installation.asset_ids(:workflow_rule_ids))
        scope = scope.where('workflow_runs.started_at >= ?', since) if since
        scope = scope.where(entity_id: deal_id) if deal_id
        runs = scope.to_a
        return runs unless location_ids

        visible = Deal.where(company_id: installation.company_id, id: runs.map(&:entity_id).uniq, location_id: location_ids).pluck(:id)
        runs.select { |run| visible.include?(run.entity_id) }
      end

      # Executed steps of these runs, each tagged with its rule's group when
      # groups are given.
      def step_rows(run_ids, groups = {})
        return [] if run_ids.empty?

        rule_of_run = WorkflowRun.where(id: run_ids).pluck(:id, :workflow_rule_id).to_h
        WorkflowRunStep.where(workflow_run_id: run_ids).order(:created_at, :id)
                       .pluck(:workflow_run_id, :step_id, :step_type, :status, :output, :error, :created_at)
                       .map do |(run_id, step_id, step_type, status, output, error, at)|
          { run_id: run_id, rule_group: groups[rule_of_run[run_id]], step_id: step_id.to_s, step_type: step_type.to_s,
            status: status, output: output || {}, error: error || {}, at: at }
        end
      end

      # One row per deal, by its latest run, newest first.
      def deal_rows(installation, runs)
        groups = rule_groups(installation)
        latest = runs.sort_by { |run| [run.started_at || run.created_at, run.id] }.reverse.uniq(&:entity_id)
        deals = Deal.where(company_id: installation.company_id, id: latest.map(&:entity_id))
                    .includes(:contact, :account, :owner, :source).index_by(&:id)
        activity_ids = step_rows(latest.map(&:id)).filter_map { |row| row[:output]['id'] if row[:step_type] == 'create_activity' && row[:status] == 'success' }
        activities = DealActivity.where(id: activity_ids).index_by(&:deal_id)

        latest.filter_map do |run|
          deal = deals[run.entity_id]
          next unless deal

          stage, detail, detail_at = place(run, groups[run.workflow_rule_id], activities[deal.id])
          { run: run, deal: deal, stage: stage, detail: detail, detail_at: detail_at }
        end
      end

      def place(run, group, activity)
        return ['stopped', 'The play was turned off', run.completed_at] if run.status == 'cancelled'
        return ['stopped', 'Stopped because a step failed', run.completed_at] if run.status == 'failed'

        case group
        when :won
          if run.status == 'completed'
            ['after_sale_done', 'After-sale follow-up finished', run.completed_at]
          elsif run.status == 'waiting' && run.wait_until
            next_key = run.current_step_id.to_s.delete_prefix('has_email_')
            ['after_sale', "Next: #{AFTER_SALE.dig(next_key, :title) || 'the next step'} on", run.wait_until]
          else
            ['after_sale', 'Sending the thank-you', nil]
          end
        when :lost
          ['lost', activity ? "Check-back task due" : 'Setting the check-back task', activity&.due_date]
        else
          ['in_pipeline', activity ? "Task: #{activity.subject}, due" : 'Giving the stage task', activity&.due_date]
        end
      end

      def step_counts(rows)
        rows.each_with_object(Hash.new(0)) do |row, counts|
          run = row[:run]
          next unless row[:stage] == 'after_sale' && run.status == 'waiting'

          counts[run.current_step_id.to_s.delete_prefix('has_email_')] += 1
        end
      end

      def row_json(installation, row)
        deal = row[:deal]
        run = row[:run]
        {
          lead_id: deal.id,
          record_path: "/deals/#{deal.id}",
          name: deal.customer_display_name.presence || deal.name.presence || "Deal ##{deal.id}",
          email: deal.contact&.email,
          source: deal.source&.name,
          rep: deal.owner && LeadResponsePlay.display_name(deal.owner),
          started_at: (run.started_at || run.created_at)&.iso8601,
          stage: row[:stage],
          stage_label: STAGES.fetch(row[:stage]),
          detail: row[:detail],
          detail_at: row[:detail_at]&.iso8601
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
      self.class.validate_content!(content, @company)

      ActiveRecord::Base.transaction do
        tag = @company.tags.find_or_create_by!(name: DONE_TAG) do |t|
          t.color = '#0F766E'
          t.is_active = true
          t.is_system = false
        end
        created_tag_ids = tag.previously_new_record? ? [tag.id] : []

        rules = sync_rules({})
        PlayInstallation.create!(
          company_id: @company.id,
          play_key: KEY,
          status: 'active',
          answers: { content: content },
          assets: assets_for(rules, {}).merge('tag_ids' => created_tag_ids),
          installed_by_user_id: @user&.id,
          installed_at: Time.current
        )
      end
    end

    # Rules are updated in place. A deal already partway through its
    # after-sale follow-up keeps the version it started with; a part turned
    # off stops, and its waiting runs are cancelled.
    def customize!
      raise InstallError, "#{NAME} is not on." unless @installation&.status == 'active'
      self.class.validate_content!(content, @company)

      ActiveRecord::Base.transaction do
        assets = (@installation.assets || {}).deep_stringify_keys
        rules = sync_rules(assets['rules'] || {})
        @installation.update!(answers: { content: content }, assets: assets_for(rules, assets))
      end
      @installation
    end

    private

    def content
      @content ||= self.class.normalize_content(@answers['content'])
    end

    # { 'won' => rule|nil, 'lost' => rule|nil, 'stages' => { key => rule } }
    def sync_rules(current)
      won = sync_rule(current['won'], won_graph, "#{NAME}: deal won", trigger('deal.won'), [])
      lost = sync_rule(current['lost'], lost_graph, "#{NAME}: deal lost", trigger('deal.lost'), [])

      existing_stages = (current['stages'] || {}).transform_keys(&:to_s)
      stages = {}
      content['stage_tasks'].each do |task|
        rule = sync_rule(existing_stages[task['stage']], stage_graph(task),
                         "#{NAME}: #{self.class.stage_label(@company, task['stage'])}",
                         trigger('deal.status_changed'),
                         [{ 'field' => 'trigger.to', 'operator' => 'equals', 'value' => task['stage'] }])
        stages[task['stage']] = rule
      end
      (existing_stages.keys - stages.keys).each do |stage|
        rule = WorkflowRule.find_by(company_id: @company.id, id: existing_stages[stage])
        self.class.archive_rule!(rule) if rule
      end

      { 'won' => won, 'lost' => lost, 'stages' => stages }
    end

    def sync_rule(existing_id, steps, name, trigger, conditions)
      rule = existing_id && WorkflowRule.find_by(company_id: @company.id, id: existing_id)
      if steps.nil?
        self.class.archive_rule!(rule) if rule
        return nil
      end

      if rule && rule.status != 'archived'
        rule.update!(steps: steps, trigger: trigger, conditions: conditions)
        ensure_valid!(rule)
        return rule
      end

      created = @company.workflow_rules.create!(
        name: unique_name(name),
        description: "Created by the #{NAME} play.",
        entity_type: 'Deal',
        status: 'draft',
        trigger: trigger,
        conditions: conditions,
        steps: steps,
        parameters: {},
        halt_on_reply: 'false',
        created_by_user_id: @user&.id
      )
      ensure_valid!(created)
      created.update!(status: 'active')
      created
    end

    def assets_for(rules, previous)
      group_ids = lambda do |group, ids|
        (Array(previous["#{group}_rule_ids"]).map(&:to_i) + ids.compact.map(&:id)).uniq
      end
      won_ids = group_ids.call('won', [rules['won']])
      lost_ids = group_ids.call('lost', [rules['lost']])
      stage_ids = group_ids.call('stage', rules['stages'].values)

      previous.except('rules').merge(
        'rules' => {
          'won' => rules['won']&.id,
          'lost' => rules['lost']&.id,
          'stages' => rules['stages'].transform_values(&:id)
        },
        'won_rule_ids' => won_ids,
        'lost_rule_ids' => lost_ids,
        'stage_rule_ids' => stage_ids,
        'workflow_rule_ids' => (won_ids + lost_ids + stage_ids).uniq
      )
    end

    def ensure_valid!(rule)
      validation = WorkflowRuleValidator.new(rule).validate
      return if validation.valid?

      raise InstallError, "The play could not switch on #{rule.name}: #{validation.errors.first}"
    end

    def unique_name(base)
      scope = @company.workflow_rules.where.not(status: 'archived')
      return base unless scope.exists?(name: base)

      (2..100).each do |n|
        candidate = "#{base} (#{n})"
        return candidate unless scope.exists?(name: candidate)
      end
      "#{base} #{SecureRandom.hex(2)}"
    end

    def trigger(event_type)
      { 'event_type' => event_type, 'entity_type_filter' => 'Deal' }
    end

    # ── The workflows ────────────────────────────────────────────────────
    #
    # won: [wait] -> has email? -> thank-you -> [wait] -> check-in task ->
    #      [wait] -> has email? -> review request -> ... -> tag after-sale-done
    def won_graph
      items = self.class.after_sale_items(content)
      return nil if items.empty?

      @nodes = []
      @edges = []
      previous_day = 0
      entries = items.map do |item|
        entry = item[:day] > previous_day ? "wait_#{item[:key]}" : first_node_id(item)
        previous_day = item[:day]
        entry
      end

      previous_day = 0
      items.each_with_index do |item, index|
        key = item[:key]
        after = entries[index + 1] || 'finish'
        if item[:day] > previous_day
          node("wait_#{key}", 'wait', { 'duration' => item[:day] - previous_day, 'unit' => 'days' }, first_node_id(item))
        end
        previous_day = item[:day]
        settings = content[key]

        if AFTER_SALE[key][:type] == :email
          # Checks the address the send will use. A blank one would send the
          # buyer's email to the rep instead.
          branch("has_email_#{key}", { 'field' => 'variables.entity.contact_email', 'operator' => 'is_set' }, key, after)
          node(key, 'send_email', { 'to' => '{{entity.contact_email}}', 'subject' => email_text(settings['subject']),
                                    'body' => email_html(key) }, after)
        else
          node(key, 'create_activity', {
            'activity_type' => 'call',
            'subject' => task_text(settings['subject']),
            'description' => 'Created by the Deal to sold play. Buyer: {{contact.full_name}} {{entity.contact_email}}',
            'priority' => 'medium',
            'assigned_to' => 'owner',
            'due_in_hours' => 24
          }, after)
        end
      end
      node('finish', 'add_tag', { 'tag_names' => [DONE_TAG] })
      { 'nodes' => @nodes, 'edges' => @edges }
    end

    def lost_graph
      lost = content['lost_check_in']
      return nil unless lost['enabled']

      single_task('lost_check_in', lost['subject'], lost['days'],
                  'Created by the Deal to sold play. This deal was lost; see whether anything has changed.')
    end

    def stage_graph(task)
      single_task('stage_task', task['subject'], task['due_days'],
                  "Created by the Deal to sold play when the deal reached #{self.class.stage_label(@company, task['stage'])}.")
    end

    def single_task(id, subject, due_days, description)
      @nodes = []
      @edges = []
      node(id, 'create_activity', {
        'activity_type' => 'task',
        'subject' => task_text(subject),
        'description' => description,
        'priority' => 'medium',
        'assigned_to' => 'owner',
        'due_in_days' => due_days,
        'due_time' => '09:00'
      })
      { 'nodes' => @nodes, 'edges' => @edges }
    end

    def first_node_id(item)
      AFTER_SALE[item[:key]][:type] == :email ? "has_email_#{item[:key]}" : item[:key]
    end

    def node(id, type, config, next_id = nil)
      @nodes << { 'id' => id, 'type' => type, 'config' => config }
      edge(id, next_id) if next_id
    end

    def branch(id, condition, on_true, on_false)
      node(id, 'branch', { 'condition' => condition, 'on_true_branch' => on_true, 'on_false_branch' => on_false })
      edge(id, on_true)
      edge(id, on_false)
    end

    def edge(from, to)
      @edges << { 'id' => "e_#{from}_#{to}", 'source' => from, 'target' => to }
    end

    # ── The dealer's words ───────────────────────────────────────────────

    def email_text(text)
      text.to_s.gsub(FIELD_PATTERN) do
        target = EMAIL_FIELDS.fetch(Regexp.last_match(1))
        target == :dealership ? @company.name : target
      end
    end

    def task_text(text)
      text.to_s.gsub(FIELD_PATTERN) { TASK_FIELDS.fetch(Regexp.last_match(1)) }
    end

    def email_html(key)
      settings = content[key]
      html = ERB::Util.html_escape(settings['body']).split(/\n{2,}/).map { |p| "<p>#{p.strip.gsub("\n", '<br>')}</p>" }.join
      html = html.gsub(FIELD_PATTERN) do
        target = EMAIL_FIELDS.fetch(Regexp.last_match(1))
        target == :dealership ? ERB::Util.html_escape(@company.name) : target
      end
      if key == 'review_request'
        link = ERB::Util.html_escape(settings['review_link'])
        html += %(<p><a href="#{link}">Leave a review</a></p>)
      end
      html
    end
  end
end
