# frozen_string_literal: true

module Outreach
  # Writes the opening message, follow-ups and replies in the sender's name
  # (backlog E105). Only from approved facts, playbook answers and content.
  class Writer
    Result = Struct.new(:body, :subject, :content_item, :book_slot, :handoff, :handoff_reason, :stop, :summary, :problem, keyword_init: true)
    HANDOFF_REASONS = %w[asked_for_person upset legal_or_warranty ready_to_buy unsure appointment other].freeze
    HISTORY = 14

    TOOL = {
      name: 'write_message',
      description: 'Return the next message.',
      input_schema: {
        type: 'object',
        properties: {
          body: { type: 'string', description: 'The message. No greeting line or signature in an email; both are added for you.' },
          subject: { type: 'string', description: 'Email only: a plain subject under 60 characters.' },
          content_id: { type: 'string', description: 'The [C number] of one video to share, or omit.' },
          book_slot: { type: 'string', description: 'The [id] from OPEN TIMES they clearly accepted. Omit otherwise.' },
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

    def opener(channel)
      write(channel, 'opener', task: 'This is your FIRST message to them. Say who you are and why you are reaching out, tie it to the show or list they came from, ' \
                                     'share the one video most likely to matter to them, and ask one easy question. Do not offer times yet.')
    end

    def follow_up(channel, number:, of:)
      stage = number >= of ? 'a polite last note saying you will stop reaching out unless they want a demo' : 'one new, useful point and one easy question'
      write(channel, 'follow_up', task: "They have not answered. This is follow-up #{number} of #{of}. Write #{stage}. Do not repeat earlier messages, do not guilt them. " \
                                        'Share a video they have not seen if one fits.')
    end

    def reply(channel, booking:)
      @booking = booking
      write(channel, 'reply', task: 'Answer their latest message. Use the playbook answer when one fits. When they are open to it, offer EXACTLY TWO times from OPEN TIMES in ' \
                                    'plain words, never the [id]. When they clearly accept one, set book_slot and keep the body to a few warm words: the confirmation is sent ' \
                                    'for you. Hand off if they ask for the sender, are upset, raise contract, legal or security terms, want to negotiate, or ask something you ' \
                                    'have no approved answer for.')
    end

    private

    def write(channel, feature, task:)
      feedback = nil
      result = nil
      2.times do
        input = AiClient.call(company: @company, feature: feature, system: system_prompt(channel, task), user: conversation_text(feedback), tool: TOOL)
        result = build(input)
        feedback = Guard.violation(result.body, channel: channel, lead: @lead)
        return result if feedback.nil?
      end
      result.problem = feedback
      result
    end

    def build(input)
      item = content.detect { |c| "C#{c.id}" == input['content_id'].to_s.strip.upcase }
      Result.new(body: Assistant::Rules.tidy(input['body']), subject: Assistant::Rules.tidy(input['subject']).truncate(80).presence,
                 content_item: item, book_slot: input['book_slot'].to_s.strip.upcase.presence, handoff: input['handoff'] == true,
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
        1. #{channel.to_s == 'email' ? 'Email style: two to four short sentences, plain words, no lists.' : 'Text style: one or two short sentences, under 260 characters.'}
        2. Say only what PRODUCT FACTS, PLAYBOOK and HELP ARTICLES support. Never invent a feature, customer, result, story or policy.
        3. Never state a price, range, discount or contract term.
        4. Never say or imply you are a human. If asked whether you are AI, say so honestly.
        5. #{Guard.visited_booth?(@lead) ? 'They visited the booth, so you may say so.' : 'You have NOT met this person. Never say you met, spoke with or saw them, and never mention a booth visit.'}
        6. Never write a web address. To share a video set content_id; the link is added for you.
        7. Never say anything negative about a competitor.
        8. Do not use dashes as punctuation. No emojis.

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

    def lead_facts
      custom = @lead.custom_field_values.to_h
      {
        'First name' => @lead.first_name, 'Company' => @lead.company_name, 'State' => @lead.state,
        'Came from' => @lead.source&.name, 'Locations' => custom['number_of_dealership_locations'],
        'Uses today' => custom['competition'], 'Why chosen' => @target.ai_reason
      }.compact_blank.map { |k, v| "#{k}: #{v}" }.join("\n")
    end
  end
end
