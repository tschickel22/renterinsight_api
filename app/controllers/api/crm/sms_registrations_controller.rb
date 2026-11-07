# frozen_string_literal: true

module Api
  module Crm
    # Settings, Communications, "Set up your texting number" (E96 phase 4).
    # The dealer fills in and submits; a platform admin sends it to the
    # carriers (Api::Admin::SmsRegistrationsController).
    class SmsRegistrationsController < ApplicationController
      before_action :set_company_scope

      def show
        return unless authorize_action!('company_settings', 'read')

        render json: payload(SmsRegistration.prefilled_for(@company))
      end

      def update
        return unless authorize_action!('company_settings', 'update')

        registration = SmsRegistration.prefilled_for(@company)
        return render(json: { error: 'This registration is with the carriers and cannot be changed now' }, status: :conflict) unless registration.editable?

        attrs = params.require(:registration).permit(
          :brand_type, :preferred_area_code,
          business: SmsRegistration::BUSINESS_FIELDS, contact: SmsRegistration::CONTACT_FIELDS, consent: [:notes, { sources: [] }]
        ).to_h
        registration.assign_attributes(
          brand_type: SmsRegistration::BRAND_TYPES.include?(attrs['brand_type']) ? attrs['brand_type'] : registration.brand_type,
          preferred_area_code: attrs.key?('preferred_area_code') ? attrs['preferred_area_code'].to_s.gsub(/\D/, '').presence : registration.preferred_area_code,
          business: registration.business.merge(attrs['business'].to_h),
          contact: registration.contact.merge(attrs['contact'].to_h),
          consent: attrs.key?('consent') ? attrs['consent'] : registration.consent
        )
        registration.save!
        render json: payload(registration)
      end

      def submit
        return unless authorize_action!('company_settings', 'update')

        registration = SmsRegistration.prefilled_for(@company)
        return render(json: { error: 'Already submitted' }, status: :conflict) unless registration.editable?

        problems = registration.problems
        return render(json: { error: 'Some answers are missing', problems: problems }, status: :unprocessable_entity) if problems.any?

        registration.update!(status: 'submitted', submitted_at: Time.current, submitted_by_user_id: current_user.id,
                             rejection_reason: nil)
        registration.log!('submitted', current_user.email)
        render json: payload(registration)
      end

      private

      def payload(r)
        content = r.campaign_content
        {
          registration: {
            id: r.id, status: r.status, brand_type: r.brand_type, business: r.business, contact: r.contact, consent: r.consent,
            preferred_area_code: r.preferred_area_code, phone_number: r.phone_number, rejection_reason: r.rejection_reason,
            submitted_at: r.submitted_at, live_at: r.live_at, editable: r.editable?
          },
          stages: r.stages,
          problems: r.problems,
          # What we will register, shown so the dealer can see it names them.
          preview: { inquiry_consent: content.inquiry_consent, marketing_consent: content.marketing_consent,
                     samples: content.message_samples.first(2) },
          options: { brand_types: SmsRegistration::BRAND_TYPES, business_types: SmsRegistration::BUSINESS_TYPES,
                     consent_sources: SmsRegistration::CONSENT_SOURCES },
          has_own_number: TwilioAccount.active.where(company_id: @company.id).exists?
        }
      end
    end
  end
end
