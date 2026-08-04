# frozen_string_literal: true

module Api
  module Contractor
    class ProfileController < BaseController
      # GET /api/contractor/profile
      def show
        render json: profile_json(current_contractor)
      end

      # PATCH /api/contractor/profile
      def update
        attrs = profile_params.to_h

        # Self-service consent is the strongest kind, but it still needs a source
        # stamped on it or we cannot tell it apart from a dealer-recorded flip.
        consent_change = attrs.key?('sms_opt_in') &&
          ActiveModel::Type::Boolean.new.cast(attrs['sms_opt_in']) != current_contractor.sms_opt_in?
        new_consent = attrs.delete('sms_opt_in')

        if current_contractor.update(attrs)
          if consent_change
            current_contractor.record_sms_consent!(
              opted_in: ActiveModel::Type::Boolean.new.cast(new_consent),
              source: 'contractor_portal',
              note: 'Contractor enabled text notifications in the Contractor Portal'
            )
          end
          render json: profile_json(current_contractor.reload)
        else
          render json: { errors: current_contractor.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # POST /api/contractor/profile/set_password
      def set_password
        if params[:password].blank? || params[:password].length < 8
          return render json: { error: 'Password must be at least 8 characters' }, status: :unprocessable_entity
        end

        if params[:password] != params[:password_confirmation]
          return render json: { error: 'Password confirmation does not match' }, status: :unprocessable_entity
        end

        if current_contractor.can_login_with_password?
          unless current_contractor.authenticate(params[:current_password])
            return render json: { error: 'Current password is incorrect' }, status: :unprocessable_entity
          end
        end

        if current_contractor.update(password: params[:password], password_login_enabled: true)
          # Sync password to all records with same email so login works across all dealers
          other_records = ::Contractor.where(email: current_contractor.email.downcase.strip, is_deleted: [false, nil])
            .where.not(id: current_contractor.id)

          if other_records.any?
            other_records.update_all(
              password_digest: current_contractor.password_digest,
              password_login_enabled: true,
              updated_at: Time.current
            )
            Rails.logger.info "[ContractorPortal] Synced password to #{other_records.count} other records for #{current_contractor.email}"
          end

          render json: { message: 'Password set successfully' }
        else
          render json: { errors: current_contractor.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # POST /api/contractor/profile/sync_credentials
      def sync_credentials
        render json: {
          error: 'premium_required',
          message: 'Credential sync is a premium feature. Upgrade to Pro to sync your license, insurance, and bond info across all dealers automatically.',
          feature: 'credential_sync',
          current_companies: all_contractors.includes(:company).map { |c|
            { id: c.company_id, name: c.company&.name }
          }.uniq { |c| c[:id] }
        }, status: :payment_required
      end

      private

      def profile_params
        params.require(:contractor).permit(
          :contact_name, :email, :phone, :trade_type, :notes, :sms_opt_in,
          :license_number, :license_state, :license_expiry,
          :insurance_provider, :insurance_policy_number, :insurance_expiry,
          :bond_amount, :bond_expiry
        )
      end

      def profile_json(contractor)
        company = contractor.company
        {
          id: contractor.id,
          name: contractor.name,
          contact_name: contractor.contact_name,
          email: contractor.email,
          phone: contractor.phone,
          sms_opt_in: contractor.sms_opt_in,
          trade_type: contractor.trade_type,
          license_number: contractor.license_number,
          license_state: contractor.license_state,
          license_expiry: contractor.license_expiry,
          insurance_provider: contractor.insurance_provider,
          insurance_policy_number: contractor.insurance_policy_number,
          insurance_expiry: contractor.insurance_expiry,
          bonded: contractor.bonded,
          bond_amount: contractor.bond_amount,
          bond_expiry: contractor.bond_expiry,
          notes: contractor.notes,
          rating: contractor.rating,
          status: contractor.status,
          company_name: company&.name,
          company_city: company&.city,
          company_state: company&.state,
          company_phone: company&.phone,
          last_portal_login_at: contractor.last_portal_login_at,
          password_login_enabled: contractor.try(:password_login_enabled) || false,
          created_at: contractor.created_at
        }
      end
    end
  end
end
