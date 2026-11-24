# frozen_string_literal: true

module Guide
  module Setup
    # A dealership's texting and phone setup, for the help assistant (E118
    # step 3). Phone and texting were the second most asked area (12 of 73
    # customer questions in the month before): which number texts go out
    # from, why changing the From number did not change it, where a texting
    # registration stands, and whether 3CX is sending calls and chats.
    #
    # Named fields only. The communications setting also holds the Twilio auth
    # token, and texting registrations hold the business's tax id; neither is
    # read here.
    class Texting
      THREE_CX_KEY = '3CX phone system'

      def initialize(ctx)
        @ctx = ctx
        @company = ctx.company
      end

      def to_h
        {
          numbers: fact { numbers },
          texts_go_out_from: fact { sends_from },
          from_number_in_settings: fact { settings_from_number },
          registration: fact { registration },
          phone_system_3cx: fact { three_cx }
        }.compact
      end

      private

      # A savepoint, so one failed query never spoils the ones after it.
      def fact(&block)
        ActiveRecord::Base.transaction(requires_new: true, &block)
      rescue StandardError => e
        Rails.logger.info("[Guide::Setup::Texting] skipped a fact: #{e.class} #{e.message}")
        nil
      end

      def accounts
        @accounts ||= @company.twilio_accounts.order(:id).to_a
      end

      def numbers
        return 'No texting number is connected.' if accounts.empty?

        accounts.map do |a|
          { number: a.phone_number, status: a.status,
            serves: a.location_id ? @ctx.location_names[a.location_id] || "location #{a.location_id}" : 'the whole company',
            account: a.own_account? ? "the dealer's own Twilio account" : "#{Brand.current(company: @company).name}'s texting service",
            connected_on: a.provisioned_at&.to_date&.iso8601 }.compact
        end
      end

      # The number each location's texts go out from: its own active number,
      # else the company-wide one (TwilioAccount.resolve_for, what sending uses).
      def sends_from
        locations = @company.locations.where(active: true, is_deleted: false).order(:name).limit(20).to_a
        rows = locations.to_h do |loc|
          account = TwilioAccount.resolve_for(company_id: @company.id, location_id: loc.id)
          [loc.name, account ? account.phone_number : 'no active number of its own or for the whole company']
        end
        company_wide = TwilioAccount.resolve_for(company_id: @company.id)
        rows.presence || { 'whole company' => company_wide&.phone_number || 'no active number' }
      end

      def settings_from_number
        sms = ((Setting.get('Company', @company.id, 'communications', nil) || {})['sms'] || {})
        from = sms['fromNumber'].presence
        return nil unless from

        connected = accounts.map { |a| a.phone_number.to_s.gsub(/\D/, '').last(10) }
        if connected.include?(from.to_s.gsub(/\D/, '').last(10))
          { number: from, note: 'Matches a connected number.' }
        else
          { number: from,
            note: 'This is not one of the connected numbers. Changing the From number in Settings does not change the ' \
                  'number texts go out from: that is the connected number for the location. Support switches the ' \
                  'connected number.' }
        end
      end

      def registration
        reg = SmsRegistration.where(company_id: @company.id).order(created_at: :desc).first
        return 'No texting registration has been started.' unless reg

        done = Array(reg.stages).select { |s| s[:done] }.map { |s| s[:label] }
        next_step = Array(reg.stages).find { |s| !s[:done] }&.dig(:label)
        { status: reg.status, steps_done: done.presence, waiting_on: next_step,
          still_needed: (reg.problems.first(8).presence if reg.editable?) }.compact
      end

      def three_cx
        key = @company.api_keys.where(name: THREE_CX_KEY).order(created_at: :desc).first
        active = key && key.try(:revoked_at).nil? && (!key.respond_to?(:active?) || key.active?)
        return { connected: false, note: 'Not connected. A DealerTide admin sets it up under Company Settings, Integrations, Phone System.' } unless active

        logs = @company.phone_call_logs
        { connected: true, connected_on: key.created_at&.to_date&.iso8601, last_heard_from: key.try(:last_used_at)&.iso8601,
          calls_last_30_days: logs.where(created_at: 30.days.ago..).where.not(call_type: 'sms').count,
          matched_to_a_record_last_30_days: logs.matched.where(created_at: 30.days.ago..).count,
          last_call: logs.where.not(call_type: 'sms').maximum(:created_at)&.iso8601,
          last_text_conversation: logs.where(call_type: 'sms').maximum(:created_at)&.iso8601 || 'none received' }.compact
      end
    end
  end
end
