# frozen_string_literal: true

module Assistant
  # Quinn AI books, moves and cancels a buyer's visit in the conversation
  # (E96 phase 2). Quinn offers two open times (Assistant::Availability); when
  # the buyer takes one, Quinn names its id and this makes the appointment in
  # our calendar, the same appointment a rep makes from Schedule visit, so the
  # calendar invite, reminders and the rep's calendar feed all follow.
  #
  # The time is checked again right before saving: if someone took it in the
  # meantime, the buyer is offered the next times instead. Quinn sends the
  # confirmation itself (the same words the booking text uses), so the
  # conversation stays Quinn's; the appointment's own booking text is skipped.
  class Booking
    Outcome = Struct.new(:ok, :kind, :activity, :text, keyword_init: true)

    attr_reader :conversation

    def initialize(conversation)
      @conversation = conversation
      @company = conversation.company
      @record = conversation.conversable
    end

    def settings
      @settings ||= Assistant::Settings.for(@company)
    end

    # Quinn may book here: the dealer allows it, and there is a lead or
    # contact to book for with a way to send the confirmation.
    def enabled?
      settings.books_visits? && Assistant::Appointments::MODELS.key?(@record.class.name)
    end

    def rep
      @rep ||= settings.book_with_user || begin
        owner = @company.users.find_by(id: @record.try(:owner_id))
        owner = nil unless owner&.active?
        owner || Assistant::Handoff.handoff_user(conversation)
      end
    end

    def availability
      @availability ||= Assistant::Availability.new(
        company: @company, user: rep, location: @record.try(:location),
        minutes: settings.visit_minutes, notice: settings.booking_notice_hours.hours
      )
    end

    def slots
      # Two a day for the week, so a day the buyer names has a real choice.
      @slots ||= enabled? ? availability.slots(days: 7, per_day: 2, limit: 14) : []
    end

    def current_visit
      @current_visit ||= Assistant::Appointments.upcoming_for(@record, limit: 1).first
    end

    # Lines for Quinn's prompt.
    def prompt_lines
      return '' unless enabled?

      lines = slots.map { |s| "[#{s.id}] #{s.label}" }
      lines = ['No open times in the next week.'] if lines.empty?
      lines.join("\n")
    end

    # Does what Quinn decided. nil when it decided nothing about a visit.
    def apply(result)
      return nil unless enabled?
      return cancel! if result.cancel_visit
      return nil if result.book_slot.blank?

      book!(result.book_slot)
    end

    # A visit or demo needs a phone number to reach them on (Tom, 2026-11-13).
    NEED_PHONE = 'To set that up I just need a good phone number for you. If you would rather not get texts, we will only call.'

    def book!(slot_id)
      return Outcome.new(ok: false, text: NEED_PHONE) if !current_visit && @record.try(:phone).to_s.gsub(/\D/, '').length < 10

      slot = slots.find { |s| s.id == slot_id.to_s.strip.upcase }
      return taken_outcome unless slot
      return taken_outcome unless availability.open?(slot.starts_at, ignore: current_visit)

      if current_visit
        current_visit.quinn_confirms = true
        changes = { start_time: slot.starts_at, end_time: slot.ends_at }
        changes[:duration_minutes] = settings.visit_minutes if current_visit.has_attribute?(:duration_minutes)
        current_visit.update!(changes)
        outcome(current_visit, 'moved')
      else
        outcome(create_visit!(slot), 'booked')
      end
    rescue StandardError => e
      Rails.logger.error("[Assistant::Booking] conversation #{conversation.id}: #{e.class}: #{e.message}")
      Outcome.new(ok: false, text: nil)
    end

    def cancel!
      visit = current_visit
      return nil unless visit

      visit.quinn_confirms = true
      visit.update!(status: 'cancelled')
      outcome(visit, 'cancelled')
    end

    # Quinn's own words before the confirmation, only when short: the
    # confirmation carries the time and place, and repeating them reads badly.
    def self.combine(reply, outcome)
      lead_in = reply.to_s.strip
      lead_in = '' if lead_in.length > 60 || lead_in.match?(/\d{1,2}(:\d{2})?\s*(am|pm)|\b(mon|tue|wed|thu|fri|sat|sun)[a-z]*day\b/i)
      [lead_in.presence, outcome.text].compact.join(' ')
    end

    private

    def create_visit!(slot)
      model, key = Assistant::Appointments::MODELS[@record.class.name]
      name = [@record.try(:first_name), @record.try(:last_name)].compact_blank.join(' ').presence || 'Buyer'
      visit = model.new(
        key => @record.id, user_id: rep.id, assigned_to_id: rep.id, activity_type: 'meeting', status: 'pending',
        subject: "#{visit_word}: #{name}", start_time: slot.starts_at, end_time: slot.ends_at, duration_minutes: settings.visit_minutes,
        meeting_location: address, description: description,
        metadata: { 'booked_by' => 'quinn_ai', 'conversation_id' => conversation.id }
      )
      visit.meeting_link = meeting_url if meeting_url && visit.has_attribute?(:meeting_link)
      visit.quinn_confirms = true
      visit.save!
      visit
    end

    def visit_word
      return 'Demo' if Assistant::Software.for?(@company)

      settings.video_visits? ? 'Video call' : 'Visit'
    end

    def description
      text = "Booked by #{settings.assistant_name} AI in the conversation."
      link = meeting_url
      link ? "#{text}\nJoin the video call: #{link}" : text
    end

    # The rep's own video meeting link (their profile), for a video visit.
    def meeting_url
      return nil unless settings.video_visits?

      rep.try(:meeting_url).to_s.strip.presence
    end

    # Where the appointment is: the video link for a video visit (nil when the
    # rep has none yet; the invite then says it is a video call), else the
    # dealership's address.
    def address
      return meeting_url || 'Video call' if settings.video_visits?

      place = availability.location || @company
      [place.try(:address_line1), place.try(:city), place.try(:state)].compact_blank.join(', ').presence
    end

    # After a software demo is booked: what the team wants to know before the
    # call (Tom's wording, 2026-11-13).
    DEMO_DETAILS_ASK = 'Please tell us about your business and if there is a specific feature you want us to discuss on the demo.'

    # What Quinn learned about them, kept on the booked visit's notes so the
    # rep reads it before the call. Called after each answer while the visit
    # is still ahead.
    DETAIL_LABELS = {
      'business_name' => 'Business', 'business_type' => 'Kind of business', 'locations' => 'Locations',
      'team_size' => 'Salespeople', 'current_system' => 'Uses today', 'demo_focus' => 'Wants covered on the demo'
    }.freeze

    def self.note_details!(conversation)
      record = conversation.conversable
      return unless record

      details = (conversation.qualification || {}).slice(*DETAIL_LABELS.keys).compact_blank
      return if details.empty?

      model, key = Assistant::Appointments::MODELS[record.class.name]
      visit = model&.where(key => record.id, activity_type: 'meeting', status: 'pending')
                   &.where('start_time >= ?', Time.current)
                   &.where("metadata->>'conversation_id' = ?", conversation.id.to_s)&.order(:start_time)&.first
      return unless visit

      base = visit.description.to_s.split("\n\nAbout them:").first.to_s
      about = details.map { |k, v| "#{DETAIL_LABELS[k]}: #{v.to_s.truncate(300)}" }.join("\n")
      visit.update_columns(description: "#{base}\n\nAbout them:\n#{about}")
    rescue StandardError => e
      Rails.logger.warn("[Assistant::Booking] could not note details for conversation #{conversation.id}: #{e.message}")
    end

    def outcome(visit, kind)
      customer = ::Appointments::Customer.for(visit)
      # The chat is a web page: the video link can be shown there.
      text = ::Appointments::BookingText.body(visit, customer, visit.assigned_to || visit.user, kind, links: conversation.web_chat?)
      text = "#{text} #{DEMO_DETAILS_ASK}" if kind == 'booked' && Assistant::Software.for?(@company)
      notify_rep(visit, kind)
      Outcome.new(ok: true, kind: kind, activity: visit, text: text)
    end

    # The rep hears in the app (bell, pop-up, phone) as well as by the calendar
    # invite email, so a visit booked an hour ahead is not missed.
    def notify_rep(visit, kind)
      user = visit.assigned_to || visit.user
      return unless user

      who = Assistant::Learn.display_name(@record)
      at = ::Appointments::TimeText.for(visit, @company)
      name = "#{settings.assistant_name} AI"
      title, message = case kind
                       when 'moved' then ["#{name} Moved a Visit", "#{name} moved #{who}'s visit with you to #{at}."]
                       when 'cancelled' then ["#{name} Cancelled a Visit", "#{who.sub(/\Athe /, 'The ')} cancelled the visit with you on #{at}."]
                       else ["#{name} Booked a Visit", "#{name} booked a visit with #{who} for you on #{at}."]
                       end
      NotificationService.create(
        recipient: user, notification_type: :assistant_booking, notifiable: @record, company_id: @company.id,
        title: title, message: message, action_url: "/inbox?c=#{conversation.id}", action_text: 'Open the conversation',
        location_id: @record.try(:location_id), deliver_now: true
      )
    rescue StandardError => e
      Rails.logger.error("[Assistant::Booking] notify failed for conversation #{conversation.id}: #{e.class}: #{e.message}")
    end

    # The time went while they were deciding: offer the next ones.
    def taken_outcome
      fresh = Assistant::Availability.new(company: @company, user: rep, location: @record.try(:location),
                                          minutes: settings.visit_minutes, notice: settings.booking_notice_hours.hours).slots(limit: 2)
      text = if fresh.size >= 2
               "Sorry, that time was just taken. I can do #{fresh[0].label} or #{fresh[1].label}. Which works better?"
             elsif fresh.size == 1
               "Sorry, that time was just taken. I can do #{fresh[0].label}. Would that work?"
             else
               'Sorry, that time was just taken. I will have the team reach out with a time that works.'
             end
      Outcome.new(ok: false, kind: nil, text: text)
    end
  end
end
