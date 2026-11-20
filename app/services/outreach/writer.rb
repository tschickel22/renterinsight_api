# frozen_string_literal: true

module Outreach
  # Writes the opening message, follow-ups and replies in the sender's name
  # (backlog E105). Only from approved facts, playbook answers and content.
  class Writer
    Result = Struct.new(:body, :subject, :content_item, :book_slot, :handoff, :handoff_reason, :stop, :summary, :problem, :share_report,
                        keyword_init: true)
    HANDOFF_REASONS = %w[asked_for_person upset legal_or_warranty ready_to_buy unsure appointment wants_site_scan other].freeze
    # Early messages share the TrueBuild video (Tom, 2026-11-19). Production
    # titles it "Let buyers design their home on your website".
    OPENER_VIDEO = /true\s*build|design (their|your) (own )?home/i
    HISTORY = 14

    TOOL = {
      name: 'write_message',
      description: 'Return the next message.',
      input_schema: {
        type: 'object',
        properties: {
          body: { type: 'string', description: 'The message. No greeting line or signature in an email; both are added for you.' },
          subject: { type: 'string', description: 'Email only: two to five plain words naming the problem, like a note between colleagues. Never "quick question" or the company name.' },
          content_id: { type: 'string', description: 'The [C number] of one video to share, or omit.' },
          book_slot: { type: 'string', description: 'The [id] from OPEN TIMES they clearly accepted. Omit otherwise.' },
          share_report: { type: 'boolean', description: 'True to attach their free website checkup link. Only when WEBSITE CHECKUP says you may.' },
          handoff: { type: 'boolean', description: 'True when the real sender should take over.' },
          handoff_reason: { type: 'string', enum: HANDOFF_REASONS },
          summary: { type: 'string', description: 'One sentence for the sender about where this stands. Use "they".' }
        },
        required: %w[body]
      }
    }.freeze

    def initialize(target)
      @target = target
      @lead = target.lead
      @company = target.company
      @settings = Settings.for(@company)
    end

    # How every opener and follow-up is built (Tom, 2026-11-20, after the first
    # production wave): one problem a retailer has, how we fix it, the video, and
    # a plain ask for the demo. No open questions about their process.
    SHAPE = 'Shape: name ONE everyday problem a manufactured home retailer has (pick the one the video you share shows), say in one sentence ' \
            'how %<company>s fixes it using only PRODUCT FACTS, point to the video, then ask for the %<minutes>s minute demo. Never ask an open ' \
            'question about how they work today, what their challenges are, or what they think.'

    def opener(channel)
      ask = if channel.to_s == 'email'
              'End by asking them to pick a time on the calendar link (it is added below your message for you) or reply with a day that suits them.'
            else
              'End by asking which day this week or next suits them for a quick look. No times yet; you will set the time when they answer.'
            end
      video = opener_video
      about = video ? "The video going with this message is \"#{video.title}\", so the problem you name must be the one it shows. " : ''
      intro = channel.to_s == 'email' ? '' : "Start with their first name and who you are in a few words, like \"Hi Pat, #{sender_first} with #{@company.name.split.first} here.\" "
      write(channel, 'opener', task: "This is your FIRST message to them. #{intro}#{about}#{shape} #{ask} " \
                                     'If FROM THEIR WEBSITE is given, you may use exactly one fact from it in your own words, without flattery, to make the problem ' \
                                     'feel like theirs. Never mention a search score or say their website is bad.')
    end

    def follow_up(channel, number:, of:, booking: nil)
      @booking = booking
      last = number >= of
      ask = if last
              'This is the last one: in two short sentences, say you will stop reaching out, and leave the door open to a demo whenever the timing is better.'
            elsif booking&.prompt_lines.to_s.match?(/\[/)
              'Ask for the demo by offering EXACTLY TWO times from OPEN TIMES in plain words, never the [id].' \
                "#{' Mention they can also pick any time from the calendar link below.' if channel.to_s == 'email'}"
            elsif channel.to_s == 'email'
              'Ask them to pick a time on the calendar link added below, or reply with a day that suits them.'
            else
              'Ask which day this week or next suits them for a quick look.'
            end
      engagement = Engagement.new(@target)
      variety = if engagement.engaged?
                  'Share a different video only if it shows the same problem; otherwise share none.'
                else
                  'Use a different problem and a different video from earlier messages.'
                end
      did = engagement.prompt_lines
      write(channel, 'follow_up', task: "They have not answered. This is follow-up #{number} of #{of}. #{last ? '' : shape} #{ask} " \
                                        "#{variety} Do not repeat earlier messages, do not mention " \
                                        'that they have not answered, and never write "following up", "circling back", "checking in" or "bumping".' \
                                        "#{"\n\nWHAT THEY DID WITH YOUR MESSAGES\n#{did}" if did.present?}")
    end

    def reply(channel, booking:)
      @booking = booking
      write(channel, 'reply', task: 'Answer their latest message. Use the playbook answer when one fits. When they are open to it, offer EXACTLY TWO times from OPEN TIMES in ' \
                                    'plain words, never the [id]. When they clearly accept one, set book_slot and keep the body to a few warm words: the confirmation is sent ' \
                                    'for you. Hand off if they ask for the sender, are upset, raise contract, legal or security terms, want to negotiate, or ask something you ' \
                                    'have no approved answer for.')
    end

    private

    def sender_first
      (@settings['persona_name'].presence || @settings.sender&.first_name).to_s.split.first || 'Tom'
    end

    def shape
      format(SHAPE, company: @company.name, minutes: @settings['demo_minutes'])
    end

    def write(channel, feature, task:)
      @task_kind = feature
      feedback = nil
      result = nil
      2.times do
        input = AiClient.call(company: @company, feature: feature, system: system_prompt(channel, task), user: conversation_text(feedback), tool: TOOL)
        result = build(input)
        reply = feature == 'reply'
        feedback = Guard.violation(result.body, channel: channel, lead: @lead, where_from: !reply, text_max: reply ? Guard::TEXT_MAX : Guard::FIRST_TEXT_MAX)
        feedback ||= Guard.subject_violation(result.subject, lead: @lead, company: @company) if channel.to_s == 'email' && feature != 'reply'
        return result if feedback.nil?
      end
      result.problem = feedback
      result
    end

    def build(input)
      item = content.detect { |c| "C#{c.id}" == input['content_id'].to_s.strip.upcase }
      item = opener_video || item if @task_kind == 'opener'
      Result.new(body: Assistant::Rules.tidy(input['body']), subject: Assistant::Rules.tidy(input['subject']).truncate(80).presence,
                 content_item: item, share_report: input['share_report'] == true && report_offerable?, book_slot: input['book_slot'].to_s.strip.upcase.presence, handoff: input['handoff'] == true,
                 handoff_reason: HANDOFF_REASONS.include?(input['handoff_reason']) ? input['handoff_reason'] : 'other',
                 summary: Assistant::Rules.tidy(input['summary']).truncate(300))
    end

    def system_prompt(channel, task)
      person = @settings.sender
      name = @settings['persona_name'].presence || [person&.first_name, person&.last_name].compact_blank.join(' ').presence || 'the team'
      <<~PROMPT
        You write sales messages for #{name}#{" (#{@settings['persona_title']})" if @settings['persona_title'].present?} at #{@company.name}, in the first person.
        Goal: a #{@settings['demo_minutes']} minute demo by video call.

        #{task}

        RULES. Breaking one of these is a serious failure.
        1. #{channel.to_s == 'email' ? 'Email style: three or four short sentences, 50 to 90 words, no lists, no greeting or sign off (both are added).' : (@task_kind == 'reply' ? 'Text style: one to three short sentences, under 260 characters.' : 'Text style: two or three very short sentences, 180 characters at most, no greeting beyond their first name. Put the problem in the first few words, since that is what shows on their lock screen.')}
        2. Say only what PRODUCT FACTS, PLAYBOOK and HELP ARTICLES support. Never invent a feature, customer, result, story or policy.
        3. Never state a price, range, discount or contract term.
        4. Never say or imply you are a human. If asked whether you are AI, say so honestly.
        5. #{Guard.visited_booth?(@lead) ? 'They visited the booth, so you may say so.' : 'You have NOT met this person. Never say you met, spoke with or saw them, and never mention a booth visit.'}
        6. Never write a web address or a stand-in for one like [video] or [link]. To share a video set content_id; the link is put after your message for you,
           so you can say "the video below" in an email or "here's a short video" in a text.
        7. Never say anything negative about a competitor.
        8. Do not use dashes as punctuation. No emojis.
        9. #{@task_kind == 'reply' ? "Never bring up how you got their details. Only if they ask, say plainly where it came from#{@lead.source&.name.present? ? " (#{@lead.source.name})" : ''} and offer to take them off the list." : "Never say how you got their details or where they came from: no list, show list, database, sign up, or source name.#{' You may say you met at the booth.' if Guard.visited_booth?(@lead)}"}
        10. Never name the software they use today.
        11. Sound like a busy owner writing to another owner: short plain words, contractions, about a 5th grade reading level, and sentences that do not all
            have the same shape. Never: "I hope this finds you well", "I came across", "I wanted to reach out", "quick question", "just checking in",
            "touching base", "I'd love to", "don't hesitate", "game changer", "streamline", "leverage", "elevate", "empower", "unlock", "seamless", "robust",
            "revolutionize", "cutting edge", "delve", "comprehensive", "utilize", "enhance", "furthermore", "moreover", lists of three adjectives,
            "not just X but Y", flattery about their business, exclamation marks, or a closing sentence that sums up the message.

        PRODUCT FACTS
        #{@settings['product_facts'].presence || 'None provided.'}

        PLAYBOOK (approved answers; use these words closely)
        #{playbook_lines.presence || 'None yet.'}

        HELP ARTICLES
        #{articles.presence || 'None match.'}

        VIDEOS YOU MAY SHARE
        #{content_lines.presence || 'None available.'}

        THIS PERSON
        #{lead_facts}
        #{website_facts}
        #{report_lines}

        RIGHT NOW: #{Time.current.in_time_zone(Clock.lead_zone(@lead, @company)).strftime('%A, %B %-d, %Y %-I:%M %p %Z')}
        #{"\nOPEN TIMES\n#{@booking.prompt_lines}" if @booking}
      PROMPT
    end

    def conversation_text(feedback)
      lines = history.map { |c| "#{c.direction == 'inbound' ? 'THEM' : 'YOU'}: #{plain(c.body)}" }
      text = lines.any? ? "Conversation so far:\n#{lines.join("\n")}" : 'No messages yet.'
      feedback ? "#{text}\n\nYour last draft could not be sent: #{feedback}. Write a new one." : text
    end

    def history
      return [] unless @target.conversation

      @target.conversation.history(HISTORY)
    end

    def plain(text)
      ActionView::Base.full_sanitizer.sanitize(text.to_s).squish.truncate(600)
    end

    def playbook_lines
      Array(@settings['playbook']).map { |e| "When they say \"#{e['objection']}\": #{e['answer']}#{" (Video: #{e['share_hint']})" if e['share_hint'].present?}" }.join("\n")
    end

    def articles
      inbound = history.select { |c| c.direction == 'inbound' }.last(2).map { |c| plain(c.body) }.join(' ')
      inbound.present? ? Assistant::Software.article_lines(inbound) : ''
    end

    def content
      @content ||= @company.outreach_content_items.approved.where.not(id: shared_ids).order(:title).to_a
    end

    def shared_ids
      OutreachEvent.where(outreach_target_id: @target.id, event_type: 'sent').filter_map { |e| e.metadata['content_item_id'] }
    end

    def content_lines
      content.map { |c| "[C#{c.id}] #{c.title}#{" (#{c.topic})" if c.topic.present?}#{". Use when: #{c.use_when}" if c.use_when.present?}" }.join("\n")
    end

    def opener_video
      content.detect { |c| c.title.to_s.match?(OPENER_VIDEO) }
    end

    # Their checkup can be offered once, after the opener, when their site was read.
    def report_offerable?
      @task_kind != 'opener' && @target.site_research.to_h['report'].present? && @target.site_research.to_h['report_shared_at'].blank?
    end

    def report_lines
      return '' unless @target.site_research.to_h['report'].present?

      if report_offerable?
        <<~TEXT.strip
          WEBSITE CHECKUP
          A short checkup of how their website shows up in Google and AI search is ready. You may offer it once: say it is a quick, free look at how their
          site shows up in search, set share_report true, and never write the link, the score or the findings. If they ask for the full report, a full scan,
          or to see their own site with TrueBuild on it, say #{@settings['persona_name'].presence || 'we'} will put it together personally, and hand off with
          handoff_reason wants_site_scan.
        TEXT
      else
        "WEBSITE CHECKUP\nAlready shared. If they ask for the full report, a full scan, or to see their own site with TrueBuild on it, say it will be " \
          'put together personally, and hand off with handoff_reason wants_site_scan.'
      end
    end

    # From Outreach::SiteResearch. Only facts read off their own site.
    def website_facts
      research = @target.site_research.to_h
      return '' unless research['status'] == 'found'

      lines = ['FROM THEIR WEBSITE (you may mention one of these; nothing else about their site)']
      lines << "Fact to open with: #{research['opener_fact']}" if research['opener_fact'].present?
      lines << "Summary: #{research['summary']}" if research['summary'].present?
      lines << "Brands they sell: #{research['brands'].join(', ')}" if research['brands'].present?
      lines << "Ways we could help: #{research['talking_points'].join(' | ')}" if research['talking_points'].present?
      lines.join("\n")
    end

    def lead_facts
      custom = @lead.custom_field_values.to_h
      {
        'First name' => @lead.first_name, 'Company' => @lead.company_name, 'State' => @lead.state,
        'Locations' => custom['number_of_dealership_locations'],
        # Where they came from is left out on purpose: the first wave named the list.
        'Met at' => Guard.visited_booth?(@lead) ? @lead.source&.name : nil
      }.compact_blank.map { |k, v| "#{k}: #{v}" }.join("\n")
    end
  end
end
