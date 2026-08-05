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
      #
      # Accepts either the 6-digit code (phone or email) or the high-entropy
      # token from an emailed link. The numeric path is throttled: `verify`
      # matches a code against EVERY contractor holding a live one, so an
      # unthrottled guess is a lottery ticket against the whole tenant base
      # rather than an attack on one account.
      def verify
        submitted = params[:token].to_s.strip
        return render_invalid_token if submitted.blank?

        # Long tokens are high-entropy; only the guessable short ones need a limit.
        if short_code?(submitted)
          return render_throttled if verify_attempts_exceeded?
          register_verify_attempt
        end

        contractor = find_contractor_for_token(submitted)

        if contractor && contractor.status == 'active'
          clear_verify_attempts
          contractor.consume_portal_link_token! if contractor.portal_link_token.present?
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

      MAX_VERIFY_ATTEMPTS = 10
      VERIFY_ATTEMPT_WINDOW = 15.minutes

      # A 6-digit code; anything longer is a link token.
      def short_code?(value)
        value.length <= 8 && value.match?(/\A\d+\z/)
      end

      def find_contractor_for_token(submitted)
        unless short_code?(submitted)
          candidate = ::Contractor.find_by(portal_link_token: submitted, is_deleted: [false, nil])
          return candidate&.portal_link_valid?(submitted) ? candidate : nil
        end

        candidate = ::Contractor.find_by(portal_access_token: submitted, is_deleted: [false, nil])
        candidate&.portal_token_valid?(submitted) ? candidate : nil
      end

      def verify_attempt_key
        "contractor_verify_attempts:#{request.remote_ip}"
      end

      def verify_attempts_exceeded?
        Rails.cache.read(verify_attempt_key).to_i >= MAX_VERIFY_ATTEMPTS
      end

      def register_verify_attempt
        count = Rails.cache.read(verify_attempt_key).to_i + 1
        Rails.cache.write(verify_attempt_key, count, expires_in: VERIFY_ATTEMPT_WINDOW)
      end

      def clear_verify_attempts
        Rails.cache.delete(verify_attempt_key)
      end

      def render_invalid_token
        render json: { error: 'Invalid or expired token' }, status: :unauthorized
      end

      def render_throttled
        render json: { error: 'Too many attempts. Wait a few minutes and request a new code.' },
               status: :too_many_requests
      end

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
          company_count: all_records.map(&:company_id).uniq.count,
          # Lets the portal prompt a code-only contractor to set a password, so
          # their next visit doesn't depend on another message arriving.
          has_password: primary.can_login_with_password?
        }
      end
    end
  end
end
