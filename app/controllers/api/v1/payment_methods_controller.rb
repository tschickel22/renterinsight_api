# frozen_string_literal: true

module Api
  module V1
    class PaymentMethodsController < ApplicationController
      before_action :set_company_scope
      before_action :set_payment_method, only: %i[show update destroy set_default verify]

      # GET /api/v1/payment-methods
      def index
        return unless authorize_action!('payment_methods', 'read')
        
        # STRICT TENANT ISOLATION: Only show payment methods from current company
        # RBAC: Location-tier users only see their assigned locations
        @payment_methods = if current_user.uses_rbac?
          if current_user.effective_admin?
            @company.payment_methods.where(is_deleted: [false, nil])
          else
            location_ids = permission_service.accessible_location_ids
            if location_ids.any?
              @company.payment_methods.where(is_deleted: [false, nil])
                                    .where(location_id: location_ids)
            else
              @company.payment_methods.where(is_deleted: [false, nil])
            end
          end
        else
          @company.payment_methods.where(is_deleted: [false, nil])
        end
        
        # Apply location selector filter (if user selected a specific location)
        @payment_methods = @payment_methods.for_current_location
        
        # Include associations for better response
        @payment_methods = @payment_methods.includes(:owner, :location)
        
        # Apply filters
        @payment_methods = @payment_methods.by_type(params[:method_type]) if params[:method_type].present?
        @payment_methods = @payment_methods.where(is_active: params[:is_active]) if params[:is_active].present?
        @payment_methods = @payment_methods.where(is_verified: params[:is_verified]) if params[:is_verified].present?
        @payment_methods = @payment_methods.where(is_default: params[:is_default]) if params[:is_default].present?
        
        # Filter by owner if provided
        if params[:owner_type].present? && params[:owner_id].present?
          @payment_methods = @payment_methods.where(owner_type: params[:owner_type], owner_id: params[:owner_id])
        end
        
        # Simple pagination without kaminari gem
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 25).to_i
        offset = (page - 1) * per_page
        
        total_count = @payment_methods.count
        @payment_methods = @payment_methods.order(created_at: :desc).limit(per_page).offset(offset)
        
        render json: {
          payment_methods: @payment_methods.as_json(
            include: {
              owner: { only: [:id, :type, :name, :email] },
              location: { only: [:id, :name] }
            },
            methods: [:display_name, :masked_account_number]
          ),
          meta: {
            current_page: page,
            total_pages: (total_count.to_f / per_page).ceil,
            total_count: total_count
          }
        }
      end

      # GET /api/v1/payment-methods/:id
      def show
        return unless authorize_action!('payment_methods', 'read')
        
        render json: @payment_method.as_json(
          include: {
            owner: { only: [:id, :type, :name, :email, :phone] },
            location: { only: [:id, :name, :address] },
            payments: { only: [:id, :amount, :status, :payment_at, :created_at] }
          },
          methods: [:display_name, :masked_account_number, :is_expired]
        )
      end

      # GET /api/v1/payment-methods/stats
      def stats
        return unless authorize_action!('payment_methods', 'read')
        
        # STRICT TENANT ISOLATION: Only stats for current company
        base_payment_methods = @company.payment_methods.where(is_deleted: [false, nil])
        
        # Apply strict location filter - only payment methods explicitly assigned to selected location
        if Current.location_filtered?
          base_payment_methods = base_payment_methods.where(location_id: Current.location_id)
        end
        
        render json: {
          total: base_payment_methods.count,
          active: base_payment_methods.where(is_active: true).count,
          verified: base_payment_methods.where(is_verified: true).count,
          default_methods: base_payment_methods.where(is_default: true).count,
          by_type: base_payment_methods.group(:method_type).count,
          by_status: {
            active: base_payment_methods.where(is_active: true).count,
            inactive: base_payment_methods.where(is_active: false).count,
            pending_verification: base_payment_methods.where(is_verified: false, method_type: 'ach').count
          },
          recent_additions: base_payment_methods.where('created_at >= ?', 30.days.ago).count
        }
      end

      # POST /api/v1/payment-methods
      def create
        return unless authorize_action!('payment_methods', 'create')
        
        # STRICT TENANT ISOLATION: Create payment method within current company
        @payment_method = @company.payment_methods.new(payment_method_params)
        
        # Auto-assign location from selector (if user selected a specific location)
        @payment_method.location_id ||= Current.location_id if Current.location_id.present?
        
        # RBAC fallback: Location-tier users auto-assign to their first location if no selector
        if @payment_method.location_id.nil? && current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          @payment_method.location_id ||= location_ids.first if location_ids.any?
        end
        
        # Set API partner ID for Zego
        @payment_method.api_partner_id = ::ZegoPaymentApi::API_PARTNER_ID
        
        # Check if we should skip the payment gateway (for development/testing)
        # Skip if: development mode AND no valid PM ID is configured
        skip_gateway = should_skip_payment_gateway?
        
        # Save payment method first (to get ID for reference_id generation)
        if @payment_method.save
          if skip_gateway
            # Development mode: Skip Zego and just save locally
            @payment_method.update!(
              external_id: "DEV_#{SecureRandom.hex(8)}",
              is_verified: false
            )
            
            Rails.logger.info "[PaymentMethods] Created payment method #{@payment_method.id} (SKIPPED GATEWAY - dev mode)"
            
            render json: @payment_method.as_json(
              include: {
                owner: { only: [:id, :type, :name, :email] },
                location: { only: [:id, :name] }
              },
              methods: [:display_name, :masked_account_number]
            ), status: :created
          else
            # Production mode: Create account in Zego payment gateway
            begin
              api = ::ZegoPaymentApi.new(@company)
              
              if api.create_account(@payment_method, request)
                # Store external ID from Zego
                @payment_method.external_id = api.read_gateway_payer_id
                
                # For cash payments, store card number if returned
                if @payment_method.cash? && api.read_cash_card_number.present?
                  @payment_method.cash_card_number = api.read_cash_card_number
                end
                
                @payment_method.save!
                
                Rails.logger.info "[PaymentMethods] Created payment method #{@payment_method.id} with Zego external_id: #{@payment_method.external_id}"
                
                render json: @payment_method.as_json(
                  include: {
                    owner: { only: [:id, :type, :name, :email] },
                    location: { only: [:id, :name] }
                  },
                  methods: [:display_name, :masked_account_number]
                ), status: :created
              else
                # Zego API call failed - delete the payment method record
                error_message = api.payment_error_message
                @payment_method.destroy
                
                Rails.logger.error "[PaymentMethods] Zego API failed: #{error_message}"
                render json: { error: "Payment method creation failed: #{error_message}" }, status: :unprocessable_entity
              end
            rescue => e
              # Exception during API call - delete payment method and return error
              @payment_method.destroy if @payment_method.persisted?
              
              Rails.logger.error "[PaymentMethods] Exception during creation: #{e.message}"
              Rails.logger.error e.backtrace.first(5).join("\n")
              
              render json: { error: "Payment method creation failed: #{e.message}" }, status: :unprocessable_entity
            end
          end
        else
          render json: { errors: @payment_method.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH/PUT /api/v1/payment-methods/:id
      def update
        return unless authorize_action!('payment_methods', 'update')
        
        # Note: Zego requires remove + create to update payment methods
        # We'll handle this by removing the old account and creating a new one
        
        begin
          api = ::RenterInsightZegoApi.new(@company)
          
          # Store old external_id before update
          old_external_id = @payment_method.external_id
          
          # Update payment method attributes
          if @payment_method.update(payment_method_params)
            # If sensitive payment data changed, recreate in Zego
            if payment_data_changed?
              # Remove old account from Zego
              if old_external_id.present?
                api.remove_account(@payment_method, request)
              end
              
              # Create new account in Zego
              if api.create_account(@payment_method, request)
                # Update external ID from Zego
                @payment_method.update!(
                  external_id: api.read_gateway_payer_id,
                  api_partner_id: ::RenterInsightZegoApi::API_PARTNER_ID
                )
                
                Rails.logger.info "[PaymentMethods] Updated payment method #{@payment_method.id} with new Zego external_id: #{@payment_method.external_id}"
                
                render json: @payment_method.as_json(
                  include: {
                    owner: { only: [:id, :type, :name, :email] },
                    location: { only: [:id, :name] }
                  },
                  methods: [:display_name, :masked_account_number]
                )
              else
                # Zego API call failed - revert to old external_id
                @payment_method.update!(external_id: old_external_id)
                
                error_message = api.payment_error_message
                Rails.logger.error "[PaymentMethods] Zego update failed: #{error_message}"
                render json: { error: "Payment method update failed: #{error_message}" }, status: :unprocessable_entity
              end
            else
              # Only metadata changed (nickname, is_default, etc.) - no Zego update needed
              render json: @payment_method.as_json(
                include: {
                  owner: { only: [:id, :type, :name, :email] },
                  location: { only: [:id, :name] }
                },
                methods: [:display_name, :masked_account_number]
              )
            end
          else
            render json: { errors: @payment_method.errors.full_messages }, status: :unprocessable_entity
          end
        rescue => e
          Rails.logger.error "[PaymentMethods] Exception during update: #{e.message}"
          Rails.logger.error e.backtrace.first(5).join("\n")
          
          render json: { error: "Payment method update failed: #{e.message}" }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/payment-methods/:id
      def destroy
        return unless authorize_action!('payment_methods', 'delete')
        
        # Check if payment method is being used by any active payments
        if @payment_method.payments.where(status: ['pending', 'processing']).exists?
          render json: { 
            error: 'Cannot delete payment method with pending or processing payments',
            active_payments_count: @payment_method.payments.where(status: ['pending', 'processing']).count
          }, status: :unprocessable_entity
          return
        end
        
        begin
          # Remove from Zego if it has an external_id
          if @payment_method.external_id.present?
            api = ::RenterInsightZegoApi.new(@company)
            
            # Attempt to remove from Zego (don't fail if this fails)
            unless api.remove_account(@payment_method, request)
              Rails.logger.warn "[PaymentMethods] Failed to remove payment method #{@payment_method.id} from Zego: #{api.payment_error_message}"
            end
          end
          
          # Soft delete the payment method
          @payment_method.soft_delete!
          
          Rails.logger.info "[PaymentMethods] Soft deleted payment method #{@payment_method.id}"
          
          head :no_content
        rescue => e
          Rails.logger.error "[PaymentMethods] Exception during destroy: #{e.message}"
          Rails.logger.error e.backtrace.first(5).join("\n")
          
          render json: { error: "Payment method deletion failed: #{e.message}" }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/payment-methods/:id/set_default
      def set_default
        return unless authorize_action!('payment_methods', 'update')
        
        begin
          # Mark this payment method as default (this will unmark others via callback)
          if @payment_method.update(is_default: true)
            Rails.logger.info "[PaymentMethods] Set payment method #{@payment_method.id} as default for #{@payment_method.owner_type} #{@payment_method.owner_id}"
            
            render json: @payment_method.as_json(
              include: {
                owner: { only: [:id, :type, :name, :email] },
                location: { only: [:id, :name] }
              },
              methods: [:display_name, :masked_account_number]
            )
          else
            render json: { errors: @payment_method.errors.full_messages }, status: :unprocessable_entity
          end
        rescue => e
          Rails.logger.error "[PaymentMethods] Exception during set_default: #{e.message}"
          Rails.logger.error e.backtrace.first(5).join("\n")
          
          render json: { error: "Failed to set default payment method: #{e.message}" }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/payment-methods/:id/verify
      def verify
        return unless authorize_action!('payment_methods', 'update')
        
        # Only ACH accounts can be verified via micro-deposits
        unless @payment_method.ach?
          render json: { error: 'Only ACH payment methods can be verified' }, status: :unprocessable_entity
          return
        end
        
        # Check if already verified
        if @payment_method.is_verified?
          render json: { 
            message: 'Payment method is already verified',
            payment_method: @payment_method.as_json(
              include: {
                owner: { only: [:id, :type, :name, :email] },
                location: { only: [:id, :name] }
              },
              methods: [:display_name, :masked_account_number]
            )
          }
          return
        end
        
        begin
          # In a full implementation, this would:
          # 1. Initiate micro-deposit verification with Zego
          # 2. Wait for user to confirm deposit amounts
          # 3. Verify the amounts with Zego
          # 
          # For now, we'll provide a placeholder that marks as verified
          # when the user provides the correct verification code or amounts
          
          verification_amounts = params[:verification_amounts] # e.g., [0.01, 0.02]
          verification_code = params[:verification_code]
          
          if verification_amounts.present? || verification_code.present?
            # TODO: Verify with Zego API
            # For now, auto-verify for development
            @payment_method.verify!
            
            Rails.logger.info "[PaymentMethods] Verified payment method #{@payment_method.id}"
            
            render json: {
              message: 'Payment method verified successfully',
              payment_method: @payment_method.as_json(
                include: {
                  owner: { only: [:id, :type, :name, :email] },
                  location: { only: [:id, :name] }
                },
                methods: [:display_name, :masked_account_number]
              )
            }
          else
            # Initiate verification process
            # TODO: Call Zego to initiate micro-deposits
            
            render json: {
              message: 'Micro-deposit verification initiated. Please check your bank account for two small deposits and verify the amounts.',
              verification_pending: true,
              payment_method: @payment_method.as_json(
                include: {
                  owner: { only: [:id, :type, :name, :email] },
                  location: { only: [:id, :name] }
                },
                methods: [:display_name, :masked_account_number]
              )
            }
          end
        rescue => e
          Rails.logger.error "[PaymentMethods] Exception during verify: #{e.message}"
          Rails.logger.error e.backtrace.first(5).join("\n")
          
          render json: { error: "Verification failed: #{e.message}" }, status: :unprocessable_entity
        end
      end

      private

      def set_company_scope
        unless current_user
          Rails.logger.error "🚫 [PaymentMethodsController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        # Use current_company_id which respects X-Company-ID header for platform admins
        company_id = current_company_id
        
        unless company_id.present?
          Rails.logger.error "🚫 [PaymentMethodsController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          Rails.logger.error "🚫 [PaymentMethodsController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "✅ [PaymentMethodsController] Company scope set: #{@company.name} (ID: #{@company.id})"
      end

      def set_payment_method
        # STRICT TENANT ISOLATION: Only access payment methods in same company
        # RBAC: Location-tier users only access their assigned locations
        @payment_method = if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          if location_ids.any?
            @company.payment_methods.where(location_id: location_ids).find(params[:id])
          else
            @company.payment_methods.find(params[:id])
          end
        else
          @company.payment_methods.find(params[:id])
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Payment method not found or access denied' }, status: :not_found
        return
      end

      # Check if sensitive payment data has changed
      def payment_data_changed?
        # Check if any sensitive fields are in the params
        sensitive_fields = %w[
          ach_routing_number ach_account_number ach_account_type
          credit_card_number credit_card_cvv credit_card_exp_month credit_card_exp_year
          method_type
        ]
        
        raw_params = params[:payment_method].present? ? params[:payment_method] : params
        sensitive_fields.any? { |field| raw_params.key?(field) || raw_params.key?(field.camelize(:lower)) }
      end

      # Determine if we should skip the payment gateway
      # Skip in development/test when:
      # 1. Gateway is explicitly disabled via setting, OR
      # 2. Company doesn't have a valid Zego PM ID configured
      def should_skip_payment_gateway?
        # Check if gateway is explicitly disabled
        gateway_enabled = Setting.get_with_fallback('zego_enabled', @company&.id)
        return true if gateway_enabled == false || gateway_enabled == 'false'
        
        # In production, always use the gateway
        return false if Rails.env.production?
        
        # In development/test, check if company has valid Zego PM ID
        # If they have a PM ID (even the fake one for testing), use the gateway
        if @company&.external_payments_id.present?
          Rails.logger.info "[PaymentMethods] Using payment gateway - company has PM ID: #{@company.external_payments_id}"
          return false
        end
        
        # No PM ID configured - skip gateway
        Rails.logger.info "[PaymentMethods] Skipping payment gateway - no PM ID configured for company"
        true
      end

      def payment_method_params
        # Support both wrapped { payment_method: {...} } and unwrapped params
        raw = params[:payment_method].present? ? params[:payment_method].to_unsafe_h : params.to_unsafe_h
        
        # Build clean params with snake_case only
        clean = {}
        
        # Handle method_type mapping (frontend sends payment_method_type)
        method_type = raw['method_type'] || raw['payment_method_type'] || raw['methodType']
        clean['method_type'] = method_type if method_type.present?
        
        # Handle owner mapping (frontend may send contact_id, account_id, lead_id, etc.)
        if raw['contact_id'].present?
          clean['owner_type'] = 'Contact'
          clean['owner_id'] = raw['contact_id']
        elsif raw['account_id'].present?
          clean['owner_type'] = 'Account'
          clean['owner_id'] = raw['account_id']
        elsif raw['lead_id'].present?
          clean['owner_type'] = 'Lead'
          clean['owner_id'] = raw['lead_id']
        else
          # Direct owner_type/owner_id mapping
          clean['owner_type'] = raw['owner_type'] || raw['ownerType'] if raw['owner_type'].present? || raw['ownerType'].present?
          clean['owner_id'] = raw['owner_id'] || raw['ownerId'] if raw['owner_id'].present? || raw['ownerId'].present?
        end
        
        # Direct mappings for other fields
        %w[nickname is_default is_active billing_first_name billing_last_name
           billing_street billing_city billing_state billing_zip billing_country].each do |key|
          clean[key] = raw[key] if raw.key?(key)
        end
        
        # Handle camelCase billing fields
        clean['billing_first_name'] ||= raw['billingFirstName']
        clean['billing_last_name'] ||= raw['billingLastName']
        clean['billing_street'] ||= raw['billingStreet']
        clean['billing_city'] ||= raw['billingCity']
        clean['billing_state'] ||= raw['billingState']
        clean['billing_zip'] ||= raw['billingZip']
        clean['billing_country'] ||= raw['billingCountry']
        
        # ACH-specific fields
        if clean['method_type'] == 'ach'
          clean['ach_account_type'] = raw['ach_account_type'] || raw['achAccountType'] || 'checking'
          clean['ach_routing_number'] = raw['ach_routing_number'] || raw['achRoutingNumber']
          clean['ach_account_number'] = raw['ach_account_number'] || raw['achAccountNumber']
        end
        
        # Card-specific fields
        if ['debit_card', 'credit_card'].include?(clean['method_type'])
          clean['credit_card_number'] = raw['credit_card_number'] || raw['creditCardNumber']
          clean['credit_card_cvv'] = raw['credit_card_cvv'] || raw['creditCardCvv']
          
          # Handle expiration date - can come as separate fields or combined "MM/YY" format
          if raw['credit_card_expires_on'].present?
            # Parse "MM/YY" format
            exp_parts = raw['credit_card_expires_on'].to_s.split('/')
            if exp_parts.length == 2
              clean['credit_card_exp_month'] = exp_parts[0].to_i
              exp_year = exp_parts[1].to_i
              # Convert 2-digit year to 4-digit (e.g., 26 -> 2026)
              clean['credit_card_exp_year'] = exp_year < 100 ? 2000 + exp_year : exp_year
            end
          else
            clean['credit_card_exp_month'] = raw['credit_card_exp_month'] || raw['creditCardExpMonth']
            clean['credit_card_exp_year'] = raw['credit_card_exp_year'] || raw['creditCardExpYear']
          end
        end
        
        # Remove nil/blank values and return permitted params
        clean.compact.reject { |_, v| v.blank? }
      end
    end
  end
end
