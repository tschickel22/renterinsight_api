module Api
  module Portal
    class BaseController < ApplicationController
      skip_before_action :authenticate
      skip_before_action :set_current_attributes
      before_action :authenticate_portal_contact

      private

      def authenticate_portal_contact
        # Use the same token format as portal auth login:
        # JWT contains buyer_portal_access_id (not contact_id)
        # This matches how current_portal_buyer works in ApplicationController
        token = request.headers['Authorization']&.split(' ')&.last

        unless token
          return render json: { error: 'Missing authorization header', code: 'token_missing' },
                        status: :unauthorized
        end

        begin
          payload = JsonWebToken.decode(token)

          # JsonWebToken.decode returns nil for expired AND malformed tokens, so
          # ask why before answering. Reporting an expired proxy token as
          # 'Invalid token' is what turned a timed-out demo into error toasts.
          unless payload && payload['buyer_portal_access_id']
            return render json: portal_auth_error, status: :unauthorized
          end

          buyer_access = BuyerPortalAccess.find_by(id: payload['buyer_portal_access_id'])

          unless buyer_access&.portal_enabled
            return render json: { error: 'Portal access disabled', code: 'portal_disabled' },
                          status: :unauthorized
          end

          # Get the contact (buyer) from BuyerPortalAccess
          @current_contact = buyer_access.buyer  # This is the Contact record

          unless @current_contact
            return render json: { error: 'Contact not found' }, status: :unauthorized
          end

          # Set company context for tenant isolation
          @company = buyer_access.company || @current_contact.company
          Current.company_id = @company.id if defined?(Current)

          # Store buyer_access for controllers that need it
          @current_buyer_access = buyer_access

        # No JWT::ExpiredSignature / JWT::DecodeError rescues here: decode
        # catches both itself and returns nil, so those clauses were dead and
        # the expiry case above is what actually reports it.
        rescue => e
          Rails.logger.error "Portal authentication error: #{e.message}"
          render json: { error: 'Authentication failed' }, status: :unauthorized
        end
      end

      def current_contact
        @current_contact
      end

      def current_buyer_access
        @current_buyer_access
      end
    end
  end
end
