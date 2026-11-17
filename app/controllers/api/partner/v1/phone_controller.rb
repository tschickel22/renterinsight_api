# frozen_string_literal: true

module Api
  module Partner
    module V1
      # What a dealer's phone system (3CX first) calls, with a partner API key
      # (Authorization: Bearer). See PhoneCalls::ThreeCxTemplate for the caller side.
      #
      #   POST|GET /phone/lookup    number          -> { contacts: [best match] }
      #   POST     /phone/contacts  number, name... -> creates a lead, same shape
      #                                                (3CX's "create contact" in its app)
      #   POST     /phone/calls     call journaling -> logs the call; an unknown
      #                                                caller becomes a lead if asked
      #   POST     /phone/chats     chat journaling -> saves an SMS conversation; an
      #                                                unknown number becomes a lead if asked
      class PhoneController < BaseController
        def lookup
          authorize_permission!('leads', 'read')
          return if performed?

          render json: { contacts: PhoneCalls::Lookup.new(current_company).by_number(params[:number]) }
        end

        def create_contact
          authorize_permission!('leads', 'write')
          return if performed?

          number = params[:number].to_s.strip
          digits = number.gsub(/\D/, '')
          return render(json: { error: 'number is required' }, status: :bad_request) if digits.length < 7

          lookup = PhoneCalls::Lookup.new(current_company)
          found = lookup.by_number(number)
          return render(json: { contacts: found }) if found.any?

          lead = PhoneCalls::LeadMaker.new(current_company).create!(
            number: number, kind: :call, first_name: given(:first_name), last_name: given(:last_name),
            email: given(:email), company_name: given(:company)
          )
          return render(json: { error: 'a full 10 digit number is required' }, status: :unprocessable_entity) unless lead

          render json: { contacts: lookup.by_number(number) }, status: :created
        end

        def calls
          authorize_permission!('leads', 'write')
          return if performed?

          attrs = params.to_unsafe_h.slice('call_type', 'direction', 'number', 'agent', 'agent_email', 'agent_name',
                                           'duration', 'started_at', 'entity_id', 'contact_id', 'create_lead')
          attrs['entity_id'] = attrs['contact_id'] if attrs['entity_id'].to_s !~ /\A(lead|contact|account)-\d+\z/i
          payload = params.to_unsafe_h.except('controller', 'action', 'format', 'phone')
          result = PhoneCalls::Recorder.new(company: current_company, provider: params[:provider].presence || '3cx')
                                       .call(attrs.except('contact_id'), payload: payload)
          render json: {
            ok: true, id: result.log&.id, duplicate: result.duplicate, created_lead: result.created_lead || false,
            matched: result.record.present?, record: result.record && PhoneCalls::Lookup.entity_id(result.record)
          }, status: result.duplicate ? :ok : :created
        end

        def chats
          authorize_permission!('leads', 'write')
          return if performed?

          attrs = params.to_unsafe_h.slice('number', 'messages', 'agent', 'agent_email', 'agent_name', 'duration',
                                           'started_at', 'ended_at', 'entity_id', 'contact_id', 'create_lead')
          attrs['entity_id'] = attrs['contact_id'] if attrs['entity_id'].to_s !~ /\A(lead|contact|account)-\d+\z/i
          payload = params.to_unsafe_h.except('controller', 'action', 'format', 'phone')
          result = PhoneCalls::ChatRecorder.new(company: current_company, provider: params[:provider].presence || '3cx')
                                           .call(attrs.except('contact_id'), payload: payload)
          render json: {
            ok: true, id: result.log&.id, duplicate: result.duplicate, created_lead: result.created_lead || false,
            matched: result.record.present?, record: result.record && PhoneCalls::Lookup.entity_id(result.record),
            opted_out: result.opted_out || false
          }, status: result.duplicate ? :ok : :created
        end

        private

        # A 3CX value that was really filled in (not left as "[FirstName]").
        def given(key)
          v = params[key].to_s.strip
          v.match?(/\A\[[^\]]*\]\z/) ? nil : v.presence
        end
      end
    end
  end
end
