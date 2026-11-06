# frozen_string_literal: true

module Api
  module Partner
    module V1
      # What a dealer's phone system (3CX first) calls, with a partner API key
      # (Authorization: Bearer). See PhoneCalls::ThreeCxTemplate for the caller side.
      #
      #   POST|GET /phone/lookup    number          -> { contacts: [best match] }
      #   POST     /phone/contacts  number          -> creates a lead, same shape
      #   POST     /phone/calls     call journaling -> logs the call
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

          source = SourceResolverService.resolve(company: current_company, source_name: 'Phone call')
          current_company.leads.create!(
            first_name: 'Caller', last_name: pretty(digits), phone: number, status: 'new',
            origin: Lead::ORIGIN_API, source_id: source&.id,
            owner_id: UnmatchedTextRouting.new(current_company).next_owner_id,
            location_id: current_company.inbound_lead_location&.id,
            notes: "Created by the phone system for a call from #{number}."
          )
          render json: { contacts: lookup.by_number(number) }, status: :created
        end

        def calls
          authorize_permission!('leads', 'write')
          return if performed?

          attrs = params.to_unsafe_h.slice('call_type', 'direction', 'number', 'agent', 'agent_email', 'agent_name',
                                           'duration', 'started_at', 'entity_id', 'contact_id')
          attrs['entity_id'] = attrs['contact_id'] if attrs['entity_id'].to_s !~ /\A(lead|contact|account)-\d+\z/i
          payload = params.to_unsafe_h.except('controller', 'action', 'format', 'phone')
          result = PhoneCalls::Recorder.new(company: current_company, provider: params[:provider].presence || '3cx')
                                       .call(attrs.except('contact_id'), payload: payload)
          render json: {
            ok: true, id: result.log&.id, duplicate: result.duplicate,
            matched: result.record.present?, record: result.record && PhoneCalls::Lookup.entity_id(result.record)
          }, status: result.duplicate ? :ok : :created
        end

        private

        def pretty(digits)
          d = digits.last(10)
          d.length == 10 ? "(#{d[0, 3]}) #{d[3, 3]}-#{d[6, 4]}" : digits
        end
      end
    end
  end
end
