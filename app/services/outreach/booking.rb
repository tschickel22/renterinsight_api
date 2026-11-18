# frozen_string_literal: true

module Outreach
  # Books a demo with the outreach sender (backlog E105): the same appointment,
  # invite and reminders as Quinn's booking, on the sender's calendar and length.
  class Booking < Assistant::Booking
    class DemoSettings < SimpleDelegator
      def initialize(base, outreach)
        super(base)
        @outreach = outreach
      end

      def visit_minutes = @outreach['demo_minutes'].to_i
      def book_with_user = @outreach.sender
      def video_visits? = true
      def books_visits? = true
      def assistant_name = 'Proactive Outreach'
    end

    def settings
      @settings ||= DemoSettings.new(Assistant::Settings.for(@company), Outreach::Settings.for(@company))
    end

    private

    # The invite goes to their email, so a phone number is not needed.
    def phone_required?
      false
    end

    def booked_by
      'proactive_outreach'
    end
  end
end
