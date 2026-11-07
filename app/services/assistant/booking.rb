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
      @rep ||= begin
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

    def book!(slot_id)
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
        subject: "Visit: #{name}", start_time: slot.starts_at, end_time: slot.ends_at, duration_minutes: settings.visit_minutes,
        meeting_location: address, description: "Booked by #{settings.assistant_name} AI in the conversation.",
        metadata: { 'booked_by' => 'quinn_ai', 'conversation_id' => conversation.id }
      )
      visit.quinn_confirms = true
      visit.save!
      visit
    end

    def address
      place = availability.location || @company
      [place.try(:address_line1), place.try(:city), place.try(:state)].compact_blank.join(', ').presence
    end

    def outcome(visit, kind)
      customer = ::Appointments::Customer.for(visit)
      text = ::Appointments::BookingText.body(visit, customer, visit.assigned_to || visit.user, kind)
      Outcome.new(ok: true, kind: kind, activity: visit, text: text)
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
