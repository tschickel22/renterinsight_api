# frozen_string_literal: true

module Api
  module Portal
    class PaymentMethodsController < ApplicationController
      skip_before_action :authenticate
      before_action :authenticate_portal_buyer!
      before_action :set_payment_method, only: [:destroy, :set_default]

      # GET /api/portal/payment_methods
      def index
        contact = current_portal_buyer.buyer
        
        unless contact
          render json: { error: 'Contact not found' }, status: :not_found
          return
        end

        payment_methods = PaymentMethod.where(
          owner_type: 'Contact',
          owner_id: contact.id,
          is_deleted: [false, nil]
        ).order(is_default: :desc, created_at: :desc)

        render json: payment_methods.map { |pm| payment_method_json(pm) }
      end

      # DELETE /api/portal/payment_methods/:id
      def destroy
        @payment_method.update(is_deleted: true, deleted_at: Time.current)
        
        # If this was the default, make the next one default
        if @payment_method.is_default
          next_method = PaymentMethod.where(
            owner_type: 'Contact',
            owner_id: @payment_method.owner_id,
            is_deleted: [false, nil]
          ).where.not(id: @payment_method.id).first
          
          next_method&.update(is_default: true)
        end

        render json: { success: true }
      end

      # POST /api/portal/payment_methods/:id/set_default
      def set_default
        contact = current_portal_buyer.buyer
        
        # Remove default from all others
        PaymentMethod.where(
          owner_type: 'Contact',
          owner_id: contact.id,
          is_deleted: [false, nil]
        ).where.not(id: @payment_method.id).update_all(is_default: false)
        
        # Set this one as default
        @payment_method.update(is_default: true)
        
        render json: { success: true, payment_method: payment_method_json(@payment_method) }
      end

      private

      def set_payment_method
        contact = current_portal_buyer.buyer
        
        unless contact
          render json: { error: 'Contact not found' }, status: :not_found
          return
        end

        @payment_method = PaymentMethod.find_by(
          id: params[:id],
          owner_type: 'Contact',
          owner_id: contact.id,
          is_deleted: [false, nil]
        )

        unless @payment_method
          render json: { error: 'Payment method not found' }, status: :not_found
          return
        end
      end

      def payment_method_json(pm)
        base = {
          id: pm.id,
          method_type: pm.method_type,
          is_default: pm.is_default,
          billing_name: "#{pm.billing_first_name} #{pm.billing_last_name}".strip,
          billing_zip: pm.billing_zip,
          created_at: pm.created_at
        }

        if pm.method_type == 'ach'
          base.merge!(
            ach_last_4: pm.ach_last_4,
            ach_account_type: pm.ach_account_type&.titleize,
            display_name: "#{pm.ach_account_type&.titleize} •••• #{pm.ach_last_4}"
          )
        else
          # credit_card or debit_card
          base.merge!(
            credit_card_last_4: pm.credit_card_last_4,
            credit_card_brand: pm.credit_card_brand,
            credit_card_exp_month: pm.credit_card_exp_month,
            credit_card_exp_year: pm.credit_card_exp_year,
            is_debit_card: pm.is_debit_card,
            display_name: "#{pm.credit_card_brand || 'Card'} •••• #{pm.credit_card_last_4}"
          )
        end

        base
      end
    end
  end
end
