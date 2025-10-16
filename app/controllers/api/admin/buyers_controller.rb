module Api
  module Admin
    class BuyersController < ApplicationController
      def index
        buyers = BuyerPortalAccess.order(:email)
        
        if params[:search].present?
          search_term = "%#{params[:search]}%"
          buyers = buyers.where('email LIKE ?', search_term)
        end
        
        buyers = buyers.limit(params[:limit] || 100)
        
        render json: {
          buyers: buyers.map { |buyer|
            # Get the actual buyer record to find name
            actual_buyer = begin
              buyer.buyer_type.constantize.find_by(id: buyer.buyer_id)
            rescue
              nil
            end
            
            # Build name from available fields
            if actual_buyer.is_a?(Lead)
              name = [actual_buyer.first_name, actual_buyer.last_name].compact.join(' ')
              name = actual_buyer.email.split('@').first if name.blank?
            elsif actual_buyer.respond_to?(:name)
              name = actual_buyer.name
            elsif actual_buyer.respond_to?(:contact_name)
              name = actual_buyer.contact_name
            elsif actual_buyer.respond_to?(:first_name)
              name = [actual_buyer.first_name, actual_buyer.last_name].compact.join(' ')
            else
              name = buyer.email.split('@').first
            end
            
            {
              id: buyer.id,
              name: name.presence || buyer.email.split('@').first,
              email: buyer.email,
              label: "#{name.presence || buyer.email.split('@').first} (#{buyer.email})"
            }
          }
        }
      end
    end
  end
end
