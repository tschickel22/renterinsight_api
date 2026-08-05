# frozen_string_literal: true

module Api
  module Admin
    class BuyersController < ApplicationController
      include PersonNameSearch

      before_action :authenticate_user!
      before_action :set_company_scope

      def index
        return unless authorize_action!('documents', 'read')
        
        # Return ALL contacts (not just those with portal invites)
        # Filter out contacts without emails since they can't receive documents
        contacts = @company.contacts
                          .where(is_deleted: [false, nil])
                          .where.not(email: [nil, ''])
                          .order(:first_name, :last_name)
        
        if params[:search].present?
          contacts = contacts.where(
            person_name_where('contacts', extra: %w[email]),
            q: person_name_like(params[:search])
          )
        end
        
        contacts = contacts.limit(params[:limit] || 200)
        
        render json: {
          buyers: contacts.map { |contact| format_contact(contact) }.compact
        }
      end

      private

      def format_contact(contact)
        # Skip contacts without email (shouldn't happen due to query filter)
        return nil if contact.email.blank?
        
        # Build name from first_name + last_name, fallback to email prefix
        name = [contact.first_name, contact.last_name].compact.join(' ').strip
        name = contact.email.split('@').first if name.blank?
        
        {
          id: contact.id,  # Use Contact ID directly (not BuyerPortalAccess ID)
          name: name,
          email: contact.email,
          label: "#{name} (#{contact.email})"
        }
      end
    end
  end
end
