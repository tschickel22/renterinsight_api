# frozen_string_literal: true

module Api
  module Contractor
    class SessionsController < ApplicationController
      skip_before_action :authenticate

      # POST /api/contractor/sessions/magic_link
      def magic_link
        contractor = ::Contractor.find_by(email: params[:email]&.downcase&.strip, is_deleted: [false, nil])

        if contractor && contractor.status == 'active'
          contractor.generate_portal_token!

          CommunicationService.send_email(
            communicable: contractor,
            to: contractor.email,
            subject: 'Your Contractor Portal Login Code',
            body: "Your 6-digit login code for the Contractor Portal:\n\n" \
                  "#{contractor.portal_access_token}\n\n" \
                  "Enter this code on the login page. It expires in 30 minutes.",
            category: 'transactional'
          )
        end

        # Always return success to prevent email enumeration
        render json: { ok: true, message: 'If an account exists, a magic link has been sent' }, status: :ok
      end

      # POST /api/contractor/sessions/login
      def login
        email = params[:email]&.downcase&.strip

        contractor = ::Contractor.where(email: email, is_deleted: [false, nil], status: 'active')
          .where.not(password_digest: [nil, ''])
          .where(password_login_enabled: true)
          .first

        if contractor&.authenticate(params[:password])
          contractor.update!(last_portal_login_at: Time.current)

          all_records = ::Contractor.where(email: email, is_deleted: [false, nil], status: 'active').order(:created_at)
          primary = all_records.first || contractor

          token = Api::Contractor::BaseController.generate_contractor_token(contractor)

          render json: {
            token: token,
            contractor: contractor_info_json(primary, all_records)
          }, status: :ok
        else
          render json: { error: 'Invalid email or password' }, status: :unauthorized
        end
      end

      # POST /api/contractor/sessions/verify
      def verify
        contractor = ::Contractor.find_by(portal_access_token: params[:token], is_deleted: [false, nil])

        if contractor&.portal_token_valid?(params[:token]) && contractor.status == 'active'
          contractor.update!(portal_access_token: nil, portal_token_expires_at: nil, last_portal_login_at: Time.current)

          all_records = ::Contractor.where(email: contractor.email.downcase.strip, is_deleted: [false, nil], status: 'active').order(:created_at)
          primary = all_records.first || contractor

          token = Api::Contractor::BaseController.generate_contractor_token(contractor)

          render json: {
            token: token,
            contractor: contractor_info_json(primary, all_records)
          }, status: :ok
        else
          render json: { error: 'Invalid or expired token' }, status: :unauthorized
        end
      end

      private

      def contractor_info_json(primary, all_records)
        {
          id: primary.id,
          name: primary.name,
          email: primary.email,
          first_name: primary.contact_name || primary.name.split(' ').first,
          last_name: primary.name.include?(' ') ? primary.name.split(' ', 2).last : '',
          phone: primary.phone,
          trade_type: primary.trade_type,
          status: primary.status,
          company_name: primary.company&.name,
          company_count: all_records.map(&:company_id).uniq.count
        }
      end
    end
  end
end
