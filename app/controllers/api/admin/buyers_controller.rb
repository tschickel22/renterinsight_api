# frozen_string_literal: true

module Api
  module Admin
    class BuyersController < ApplicationController
      before_action :authenticate_user!
      before_action :set_company_scope

      def index
        return unless authorize_action!('documents', 'read')
        portal_accesses = company_scoped_portal_accesses.order(:email)
        
        if params[:search].present?
          search_term = "%#{params[:search]}%"
          portal_accesses = portal_accesses.where('email ILIKE ?', search_term)
        end
        
        portal_accesses = portal_accesses.limit(params[:limit] || 100)
        
        render json: {
          buyers: portal_accesses.map { |buyer_access| format_buyer(buyer_access) }.compact
        }
      end

      private

      def company_scoped_portal_accesses
        lead_ids = @company.leads.pluck(:id)
        contact_ids = @company.contacts.pluck(:id)

        BuyerPortalAccess.where(
          "(buyer_type = 'Lead' AND buyer_id IN (?)) OR (buyer_type = 'Contact' AND buyer_id IN (?))",
          lead_ids,
          contact_ids
        )
      end

      def format_buyer(buyer_access)
        actual_buyer = find_actual_buyer(buyer_access)
        return nil unless actual_buyer
        
        name = extract_buyer_name(actual_buyer, buyer_access)
        
        {
          id: buyer_access.id,
          name: name.presence || buyer_access.email.split('@').first,
          email: buyer_access.email,
          label: "#{name.presence || buyer_access.email.split('@').first} (#{buyer_access.email})"
        }
      end

      def find_actual_buyer(buyer_access)
        case buyer_access.buyer_type
        when 'Lead'
          @company.leads.find_by(id: buyer_access.buyer_id)
        when 'Contact'
          @company.contacts.find_by(id: buyer_access.buyer_id)
        end
      end

      def extract_buyer_name(actual_buyer, buyer_access)
        if actual_buyer.is_a?(Lead)
          name = [actual_buyer.first_name, actual_buyer.last_name].compact.join(' ')
          name.presence || actual_buyer.email&.split('@')&.first
        elsif actual_buyer.respond_to?(:name)
          actual_buyer.name
        elsif actual_buyer.respond_to?(:contact_name)
          actual_buyer.contact_name
        elsif actual_buyer.respond_to?(:first_name)
          [actual_buyer.first_name, actual_buyer.last_name].compact.join(' ')
        else
          buyer_access.email.split('@').first
        end
      end
    end
  end
end
