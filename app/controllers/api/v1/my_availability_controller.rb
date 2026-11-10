# frozen_string_literal: true

module Api
  module V1
    # A rep's own availability for visits (E96 phase 2): working hours, time
    # they blocked, the private link that puts their DealerTide appointments in
    # their own calendar, and their calendar's private address for busy times.
    # Quinn AI only offers times that are open here. Each user edits their own.
    #
    # busy_feed_detail is the rep's choice of how much of their own calendar
    # shows on their DealerTide calendar, which managers and admins can open.
    class MyAvailabilityController < ApplicationController
      before_action :set_company_scope

      DAYS = Assistant::Hours::DAYS
      TIME = /\A([01]?\d|2[0-3]):[0-5]\d\z/

      def show
        render json: payload
      end

      def update
        attrs = params.require(:availability).permit(:busy_feed_url, :busy_feed_detail, :use_location_hours, working_hours: {})
        if attrs.key?(:working_hours) || attrs.key?(:use_location_hours)
          use_location = ActiveModel::Type::Boolean.new.cast(attrs[:use_location_hours])
          current_user.update!(working_hours: use_location ? nil : clean_hours(attrs[:working_hours]))
        end
        if attrs.key?(:busy_feed_detail)
          detail = attrs[:busy_feed_detail].to_s
          unless CalendarBusyBlock::FEED_DETAILS.include?(detail)
            return render(json: { error: 'Choose what to show from your calendar' }, status: :unprocessable_entity)
          end

          change_feed_detail(detail)
        end
        if attrs.key?(:busy_feed_url)
          url = attrs[:busy_feed_url].to_s.strip.presence
          if url && !url.match?(%r{\A(https|webcal)://}i)
            return render(json: { error: 'Paste the full private address, starting with https:// or webcal://' }, status: :unprocessable_entity)
          end

          current_user.update!(busy_feed_url: url, busy_feed_error: nil, busy_feed_checked_at: nil)
          CalendarBusyBlock.where(user_id: current_user.id, source: 'feed').delete_all unless url
          BusyFeedSyncJob.perform_later(current_user.id) if url
        end
        render json: payload
      end

      # A new private link; the old one stops working.
      def reset_feed
        current_user.update!(calendar_feed_token: SecureRandom.urlsafe_base64(24))
        render json: payload
      end

      def create_block
        attrs = params.require(:block).permit(:starts_at, :ends_at, :note)
        block = CalendarBusyBlock.new(company_id: current_user.company_id, user_id: current_user.id, source: 'manual',
                                      starts_at: attrs[:starts_at], ends_at: attrs[:ends_at], note: attrs[:note].to_s.truncate(120).presence)
        return render(json: { error: block.errors.full_messages.to_sentence }, status: :unprocessable_entity) unless block.save

        render json: payload
      end

      def destroy_block
        CalendarBusyBlock.where(user_id: current_user.id, source: 'manual').find_by(id: params[:block_id])&.destroy
        render json: payload
      end

      private

      # Showing less takes effect at once: titles and places the rep no longer
      # wants shown are wiped now, not at the next read. Showing more needs a
      # fresh read, since nothing beyond what was chosen was ever stored.
      def change_feed_detail(detail)
        previous = current_user.busy_feed_detail.to_s
        return if previous == detail

        current_user.update!(busy_feed_detail: detail)
        feed_rows = CalendarBusyBlock.where(user_id: current_user.id, source: 'feed')
        feed_rows.update_all(title: nil, place: nil) unless %w[titles titles_places].include?(detail)
        feed_rows.update_all(place: nil) if detail == 'titles'
        BusyFeedSyncJob.perform_later(current_user.id) if current_user.busy_feed_url.present?
      end

      def payload
        user = current_user
        user.update!(calendar_feed_token: SecureRandom.urlsafe_base64(24)) if user.calendar_feed_token.blank?
        base = (ENV['RAILS_API_URL'].presence || request.base_url).to_s.chomp('/')
        availability = Assistant::Availability.new(company: @company, user: user, minutes: Assistant::Settings.for(@company).visit_minutes,
                                                   notice: 0.hours)
        {
          working_hours: user.working_hours,
          location_hours: Assistant::Hours.hours_for(availability.location),
          time_zone: availability.zone.tzinfo.name,
          feed_url: "#{base}/calendar/#{user.calendar_feed_token}.ics",
          busy_feed_url: user.busy_feed_url,
          busy_feed_checked_at: user.busy_feed_checked_at,
          busy_feed_error: user.busy_feed_error,
          busy_feed_detail: user.busy_feed_detail,
          busy_from_feed: CalendarBusyBlock.where(user_id: user.id, source: 'feed').where('ends_at > ?', Time.current).count,
          blocks: CalendarBusyBlock.where(user_id: user.id, source: 'manual').where('ends_at > ?', Time.current).order(:starts_at).limit(100)
                                   .map { |b| { id: b.id, starts_at: b.starts_at, ends_at: b.ends_at, note: b.note } },
          # What Quinn AI would offer for this rep now.
          open_times: availability.slots(days: 7, per_day: 2, limit: 6).map { |s| { starts_at: s.starts_at, label: s.label } }
        }
      end

      def clean_hours(raw)
        raw = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
        DAYS.index_with do |day|
          entry = raw[day].to_h.stringify_keys
          closed = ActiveModel::Type::Boolean.new.cast(entry['closed']) == true
          open = entry['open'].to_s.match?(TIME) ? entry['open'] : '09:00'
          close = entry['close'].to_s.match?(TIME) ? entry['close'] : '17:00'
          { 'open' => open, 'close' => close, 'closed' => closed }
        end
      end
    end
  end
end
