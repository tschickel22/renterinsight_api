# frozen_string_literal: true

module Api
  module V1
    class LoansController < ApplicationController
      before_action :set_company_scope
      before_action :set_loan, only: %i[show update destroy activate mark_defaulted record_payment record_manual_payment documents upload_documents destroy_document]

      # GET /api/v1/loans
      def index
        return unless authorize_action!('loans', 'read')
        
        # STRICT TENANT ISOLATION: Only show loans from current company
        # RBAC: Location-tier users only see their assigned locations
        @loans = if current_user.uses_rbac?
          if current_user.effective_admin?
            @company.loans.where(is_deleted: [false, nil])
          else
            location_ids = permission_service.accessible_location_ids
            if location_ids.any?
              @company.loans.where(is_deleted: [false, nil])
                           .where(location_id: location_ids)
            else
              @company.loans.where(is_deleted: [false, nil])
            end
          end
        else
          @company.loans.where(is_deleted: [false, nil])
        end
        
        # Apply location selector filter (if user selected a specific location)
        @loans = @loans.for_current_location
        
        # Include associations for better response
        @loans = @loans.includes(:borrower, :location, :financed_entity, :default_payment_method)
        
        # Apply filters
        @loans = @loans.search(params[:search]) if params[:search].present?
        @loans = @loans.by_status(params[:status]) if params[:status].present?
        @loans = @loans.where(loan_type: params[:loan_type]) if params[:loan_type].present?
        
        # Date range filters
        if params[:start_date].present? && params[:end_date].present?
          start_date = Date.parse(params[:start_date])
          end_date = Date.parse(params[:end_date])
          @loans = @loans.where('origination_date BETWEEN ? AND ?', start_date, end_date)
        end
        
        # Filter by borrower
        if params[:borrower_type].present? && params[:borrower_id].present?
          @loans = @loans.where(borrower_type: params[:borrower_type], borrower_id: params[:borrower_id])
        end
        
        # Past due filter
        @loans = @loans.past_due if params[:past_due] == 'true'
        
        # Auto-pay filter
        @loans = @loans.auto_pay if params[:auto_pay] == 'true'
        
        # Simple pagination without kaminari gem
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 25).to_i
        offset = (page - 1) * per_page
        
        total_count = @loans.count
        @loans = @loans.order(created_at: :desc).limit(per_page).offset(offset)
        
        render json: {
          loans: @loans.as_json(
            include: {
              borrower: { only: [:id, :type], methods: [:name] },
              location: { only: [:id, :name] },
              financed_entity: { only: [:id, :type] },
              default_payment_method: { only: [:id, :method_type, :display_name] }
            },
            methods: [:display_name, :borrower_name, :payment_progress_percentage, :remaining_balance]
          ),
          pagination: {
            current_page: page,
            per_page: per_page,
            total_pages: (total_count.to_f / per_page).ceil,
            total_count: total_count
          }
        }
      end

      # GET /api/v1/loans/stats
      def stats
        return unless authorize_action!('loans', 'read')
        
        # MUST filter stats by location context
        loans = if current_user.uses_rbac?
          if current_user.effective_admin?
            @company.loans.where(is_deleted: [false, nil])
          else
            location_ids = permission_service.accessible_location_ids
            if location_ids.any?
              @company.loans.where(is_deleted: [false, nil])
                           .where(location_id: location_ids)
            else
              @company.loans.where(is_deleted: [false, nil])
            end
          end
        else
          @company.loans.where(is_deleted: [false, nil])
        end
        
        # Apply location selector filter
        loans = loans.for_current_location
        
        # Calculate statistics
        total_loans = loans.count
        total_principal = loans.sum(:principal_amount).to_f
        total_current_balance = loans.sum(:current_balance).to_f
        total_paid = loans.sum(:total_paid).to_f
        avg_loan_amount = loans.average(:principal_amount).to_f
        avg_interest_rate = loans.average(:interest_rate).to_f
        
        # Breakdown by status
        by_status = {}
        ['pending', 'active', 'current', 'overdue', 'defaulted', 'paid_off', 'cancelled'].each do |status|
          status_loans = loans.where(status: status)
          by_status[status] = {
            count: status_loans.count,
            total_balance: status_loans.sum(:current_balance).to_f
          }
        end
        
        # Breakdown by type
        by_type = {}
        ['conventional', 'bridge', 'line_of_credit', 'chattel', 'land_home'].each do |type|
          type_loans = loans.where(loan_type: type)
          by_type[type] = {
            count: type_loans.count,
            total_balance: type_loans.sum(:current_balance).to_f
          }
        end
        
        render json: {
          total_count: total_loans,
          total_principal: total_principal,
          total_current_balance: total_current_balance,
          total_paid: total_paid,
          avg_loan_amount: avg_loan_amount.round(2),
          avg_interest_rate: avg_interest_rate.round(2),
          by_status: by_status,
          by_type: by_type
        }
      end

      # GET /api/v1/loans/:id
      def show
        return unless authorize_action!('loans', 'read')
        
        # Include payment history
        payments = @loan.payments.order(created_at: :desc).limit(50)
        
        # Get company payment settings for display
        loan_settings = @company.loan_settings || {}
        payment_settings = {
          grace_period_days: loan_settings['grace_period_days'] || 0,
          late_fee_amount: loan_settings['late_fee_amount'] || 0,
          late_fee_type: loan_settings['late_fee_type'] || 'fixed'
        }
        
        render json: {
          loan: @loan.as_json(
            include: {
              borrower: { only: [:id, :type], methods: [:name, :email, :phone] },
              location: { only: [:id, :name, :address] },
              financed_entity: { only: [:id, :type], methods: [:display_name] },
              default_payment_method: { only: [:id, :method_type, :display_name, :masked_account_number] }
            },
            methods: [:display_name, :borrower_name, :payment_progress_percentage, :remaining_balance, 
                      :days_until_next_payment, :current?, :past_due?]
          ),
          payment_history: payments.as_json(
            only: [:id, :amount, :principal_amount, :interest_amount, :status, :payment_date, :created_at],
            methods: [:display_name]
          ),
          payment_settings: payment_settings
        }
      end

      # POST /api/v1/loans
      def create
        return unless authorize_action!('loans', 'create')
        
        @loan = @company.loans.new(loan_params)
        
        # CRITICAL: Always set location_id to prevent orphaned loans
        # Priority: 1) From params, 2) Current selector, 3) First company location, 4) RBAC fallback
        if @loan.location_id.blank?
          @loan.location_id = Current.location_id if Current.location_id.present?
        end
        
        # RBAC fallback for location-tier users
        if @loan.location_id.blank? && current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          @loan.location_id = location_ids.first if location_ids.any?
        end
        
        # Final fallback: Use first company location
        if @loan.location_id.blank?
          first_location = @company.locations.active.first
          @loan.location_id = first_location.id if first_location
        end
        
        # Validate location was set
        unless @loan.location_id.present?
          render json: { error: 'Location is required. Please create a location first or select one from the dropdown.' }, status: :unprocessable_entity
          return
        end
        
        # Calculate derived fields
        if @loan.term_months.present? && @loan.interest_rate.present?
          @loan.regular_payment_amount = @loan.calculate_monthly_payment
        end
        
        ActiveRecord::Base.transaction do
          unless @loan.save
            Rails.logger.error("❌ [LoansController] Loan validation failed:")
            Rails.logger.error("   Errors: #{@loan.errors.full_messages.join(', ')}")
            Rails.logger.error("   Loan attributes: #{@loan.attributes.except('created_at', 'updated_at').inspect}")
            render json: { errors: @loan.errors.full_messages }, status: :unprocessable_entity
            raise ActiveRecord::Rollback
            return
          end
          
          # Handle document uploads
          if params[:documents].present?
            params[:documents].each do |_index, doc_params|
              next unless doc_params[:file].present?
              
              document = @loan.documents.build(
                owner: @loan,
                category: doc_params[:category] || 'general',
                document_name: doc_params[:name],
                uploaded_by: current_user.id.to_s
              )
              
              document.file.attach(doc_params[:file])
              
              unless document.save
                Rails.logger.error("❌ [LoansController] Document upload failed: #{document.errors.full_messages.join(', ')}")
                # Don't fail the whole loan creation, just log it
              end
            end
          end
        end
        
        render json: {
          loan: @loan.as_json(
            include: {
              borrower: { only: [:id, :type], methods: [:name] },
              location: { only: [:id, :name] },
              documents: { only: [:id, :name, :category, :uploaded_at], methods: [:filename, :size] }
            },
            methods: [:display_name, :borrower_name]
          )
        }, status: :created
      rescue => e
        Rails.logger.error("❌ [LoansController] Error creating loan: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
        render json: { error: e.message }, status: :internal_server_error
      end

      # PATCH /api/v1/loans/:id
      def update
        return unless authorize_action!('loans', 'update')
        
        # Protect certain fields for active loans
        if @loan.active? && update_params_contain_protected_fields?
          render json: { 
            error: 'Cannot modify principal, term, or interest rate for active loans. Consider creating a new loan instead.' 
          }, status: :unprocessable_entity
          return
        end
        
        if @loan.update(loan_params)
          # Recalculate payment amount if terms changed
          if @loan.saved_change_to_term_months? || @loan.saved_change_to_interest_rate? || @loan.saved_change_to_principal_amount?
            @loan.update(regular_payment_amount: @loan.calculate_monthly_payment)
          end
          
          render json: {
            loan: @loan.as_json(
              include: {
                borrower: { only: [:id, :type], methods: [:name] },
                location: { only: [:id, :name] }
              },
              methods: [:display_name, :borrower_name]
            )
          }
        else
          render json: { errors: @loan.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/loans/:id
      def destroy
        return unless authorize_action!('loans', 'delete')
        
        # Prevent deletion if there are payments
        if @loan.payments.exists?
          render json: { 
            error: 'Cannot delete loan with existing payments. Please cancel the loan instead.' 
          }, status: :unprocessable_entity
          return
        end
        
        # Soft delete
        if @loan.soft_delete!
          render json: { message: 'Loan deleted successfully' }
        else
          render json: { errors: @loan.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # GET /api/v1/loans/search-borrowers
      # Search for potential borrowers (Accounts or Contacts)
      def search_borrowers
        return unless authorize_action!('loans', 'read')
        
        borrower_type = params[:borrower_type]
        query = params[:query]&.strip
        
        Rails.logger.info("🔍 [search_borrowers] Type: #{borrower_type}, Query: #{query}")
        
        unless ['Account', 'Contact'].include?(borrower_type)
          render json: { error: 'Invalid borrower_type. Must be Account or Contact.' }, status: :unprocessable_entity
          return
        end
        
        # Get the appropriate model
        borrower_model = borrower_type.constantize
        
        # Base query with RBAC and location filtering
        borrowers = if current_user.uses_rbac?
          if current_user.effective_admin?
            @company.send(borrower_type.tableize)
          else
            location_ids = permission_service.accessible_location_ids
            if location_ids.any?
              @company.send(borrower_type.tableize).where(location_id: location_ids)
            else
              @company.send(borrower_type.tableize)
            end
          end
        else
          @company.send(borrower_type.tableize)
        end
        
        # Apply location selector filter
        borrowers = borrowers.for_current_location
        
        # Search by name or email
        if query.present?
          if borrower_type == 'Account'
            borrowers = borrowers.where('name ILIKE ?', "%#{query}%")
          elsif borrower_type == 'Contact'
            borrowers = borrowers.where(
              'first_name ILIKE ? OR last_name ILIKE ? OR email ILIKE ?',
              "%#{query}%", "%#{query}%", "%#{query}%"
            )
          end
        end
        
        # Limit results
        borrowers = borrowers.limit(50)
        
        # Format response
        results = borrowers.map do |borrower|
          {
            id: borrower.id,
            type: borrower_type,
            name: borrower.respond_to?(:full_name) ? borrower.full_name : borrower.name,
            email: borrower.respond_to?(:email) ? borrower.email : nil,
            display_name: borrower.respond_to?(:full_name) ? "#{borrower.full_name} (#{borrower.email})" : borrower.name
          }
        end
        
        Rails.logger.info("✅ [search_borrowers] Found #{results.count} borrowers")
        
        render json: { borrowers: results }
      end
      
      # POST /api/v1/loans/calculate-schedule
      # Calculate amortization schedule without creating a loan
      def calculate_schedule
        return unless authorize_action!('loans', 'read')
        
        principal = params[:principal_amount].to_f
        rate = params[:interest_rate].to_f
        term = params[:term_months].to_i
        frequency = params[:payment_frequency] || 'monthly'
        
        if principal <= 0 || term <= 0
          render json: { error: 'Invalid loan parameters' }, status: :unprocessable_entity
          return
        end
        
        # Calculate monthly payment
        monthly_payment = if rate == 0
          principal / term
        else
          r = (rate / 100) / 12
          n = term
          (principal * (r * (1 + r)**n)) / ((1 + r)**n - 1)
        end
        
        # Generate amortization schedule
        schedule = []
        balance = principal
        
        term.times do |i|
          interest = (balance * (rate / 100) / 12)
          principal_payment = monthly_payment - interest
          balance -= principal_payment
          balance = 0 if balance < 0.01 # Prevent rounding errors
          
          schedule << {
            payment_number: i + 1,
            payment_amount: monthly_payment.round(2),
            principal_amount: principal_payment.round(2),
            interest_amount: interest.round(2),
            remaining_balance: balance.round(2)
          }
        end
        
        total_interest = (monthly_payment * term) - principal
        
        render json: {
          summary: {
            principal_amount: principal,
            interest_rate: rate,
            term_months: term,
            payment_frequency: frequency,
            monthly_payment: monthly_payment.round(2),
            total_interest: total_interest.round(2),
            total_amount: (principal + total_interest).round(2)
          },
          schedule: schedule
        }
      end

      # POST /api/v1/loans/:id/record-payment
      # Process a payment through the payment gateway
      def record_payment
        return unless authorize_action!('payments', 'create')
        
        unless @loan.active?
          render json: { error: 'Can only record payments for active loans' }, status: :unprocessable_entity
          return
        end
        
        payment_amount = params[:amount].to_f
        payment_method_id = params[:payment_method_id]
        
        if payment_amount <= 0
          render json: { error: 'Payment amount must be greater than zero' }, status: :unprocessable_entity
          return
        end
        
        unless payment_method_id.present?
          render json: { error: 'Payment method is required' }, status: :unprocessable_entity
          return
        end
        
        # Get payment method
        payment_method = @company.payment_methods.find_by(id: payment_method_id)
        unless payment_method
          render json: { error: 'Payment method not found' }, status: :not_found
          return
        end
        
        # Verify payment method type requires gateway processing
        unless ['credit_card', 'debit_card', 'ach', 'cash'].include?(payment_method.method_type)
          render json: { error: 'Invalid payment method type for gateway processing' }, status: :unprocessable_entity
          return
        end
        
        # Create payment record
        payment = @loan.payments.new(
          company: @company,
          location: @loan.location,
          payer: @loan.borrower,
          payment_method: payment_method,
          amount: payment_amount,
          payment_date: Date.current,
          payment_type: 'loan_payment',
          gateway_name: 'zego',
          status: 'processing',
          notes: params[:notes]
        )
        
        # Calculate principal and interest breakdown
        interest_due = (@loan.current_balance * (@loan.interest_rate.to_f / 100 / 12))
        payment.interest_amount = [interest_due, payment_amount].min
        payment.principal_amount = payment_amount - payment.interest_amount
        
        if payment.save
          begin
            # Process through gateway
            api = RenterInsightZegoApi.new(@company)
            
            if api.capture_payment(payment_method, payment, request)
              # Get transaction details
              external_id = api.read_transaction_id
              
              # Mark as completed
              payment.update!(
                status: 'completed',
                external_id: external_id,
                processed_at: Time.current
              )
              
              # Update loan with payment
              @loan.process_payment!(payment)
              
              Rails.logger.info "[Loans] Successfully processed payment #{payment.id} for loan #{@loan.id}: $#{payment_amount}"
              
              render json: {
                message: 'Payment processed successfully',
                payment: payment.as_json(methods: [:display_name]),
                loan: @loan.as_json(methods: [:remaining_balance, :payment_progress_percentage])
              }
            else
              # Payment failed
              error_message = api.payment_error_message
              payment.update!(status: 'failed', failure_reason: error_message)
              
              Rails.logger.error "[Loans] Payment processing failed: #{error_message}"
              
              render json: { 
                error: "Payment failed: #{error_message}",
                payment: payment.as_json(only: [:id, :payment_number, :status, :failure_reason])
              }, status: :unprocessable_entity
            end
          rescue => e
            # Exception during processing
            payment.update!(status: 'failed', failure_reason: e.message) if payment.persisted?
            
            Rails.logger.error "[Loans] Exception during payment processing: #{e.message}"
            Rails.logger.error e.backtrace.first(5).join("\n")
            
            render json: { error: "Payment processing failed: #{e.message}" }, status: :unprocessable_entity
          end
        else
          render json: { errors: payment.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/loans/:id/record-manual-payment
      # Record an in-person payment (cash, check, money order)
      def record_manual_payment
        return unless authorize_action!('payments', 'create')
        
        unless @loan.active?
          render json: { error: 'Can only record payments for active loans' }, status: :unprocessable_entity
          return
        end
        
        payment_amount = params[:amount].to_f
        payment_date = params[:payment_date].present? ? Date.parse(params[:payment_date]) : Date.current
        manual_payment_type = params[:manual_payment_type] # 'cash', 'check', 'money_order'
        reference_number = params[:reference_number] # Check or MO number
        
        if payment_amount <= 0
          render json: { error: 'Payment amount must be greater than zero' }, status: :unprocessable_entity
          return
        end
        
        unless ['cash', 'check', 'money_order'].include?(manual_payment_type)
          render json: { error: 'Invalid manual payment type. Must be cash, check, or money_order' }, status: :unprocessable_entity
          return
        end
        
        # For checks and money orders, reference number is required
        if ['check', 'money_order'].include?(manual_payment_type) && reference_number.blank?
          render json: { error: "#{manual_payment_type.titleize} number is required" }, status: :unprocessable_entity
          return
        end
        
        # Build metadata hash with safer user name handling
        user_full_name = if current_user.respond_to?(:full_name)
          current_user.full_name
        else
          "#{current_user.first_name} #{current_user.last_name}".strip
        end
        
        # Create payment record (no payment method needed for manual)
        payment = @loan.payments.new(
          company: @company,
          location: @loan.location,
          payer: @loan.borrower,
          payment_method: nil, # No payment method for manual payments
          amount: payment_amount,
          payment_date: payment_date,
          payment_type: 'loan_payment',
          gateway_name: 'manual',
          status: 'completed',
          notes: params[:notes],
          metadata: {
            manual_payment_type: manual_payment_type,
            reference_number: reference_number,
            recorded_by: current_user.id,
            recorded_by_name: user_full_name
          }.compact
        )
        
        # Calculate principal and interest breakdown
        interest_due = (@loan.current_balance * (@loan.interest_rate.to_f / 100 / 12))
        payment.interest_amount = [interest_due, payment_amount].min
        payment.principal_amount = payment_amount - payment.interest_amount
        
        if payment.save
          # Update loan with payment
          @loan.process_payment!(payment)
          
          Rails.logger.info "[Loans] Recorded manual #{manual_payment_type} payment #{payment.id} for loan #{@loan.id}: $#{payment_amount}"
          
          render json: {
            message: 'Manual payment recorded successfully',
            payment: payment.as_json(methods: [:display_name]),
            loan: @loan.as_json(methods: [:remaining_balance, :payment_progress_percentage])
          }
        else
          render json: { errors: payment.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/loans/:id/activate
      def activate
        return unless authorize_action!('loans', 'update')
        
        unless @loan.status == 'pending'
          render json: { error: 'Only pending loans can be activated' }, status: :unprocessable_entity
          return
        end
        
        if @loan.activate!
          render json: {
            message: 'Loan activated successfully',
            loan: @loan.as_json(methods: [:display_name, :borrower_name])
          }
        else
          render json: { errors: @loan.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/loans/:id/mark-defaulted
      def mark_defaulted
        return unless authorize_action!('loans', 'update')
        
        unless @loan.active?
          render json: { error: 'Only active loans can be marked as defaulted' }, status: :unprocessable_entity
          return
        end
        
        if @loan.mark_defaulted!
          render json: {
            message: 'Loan marked as defaulted',
            loan: @loan.as_json(methods: [:display_name, :borrower_name, :remaining_balance])
          }
        else
          render json: { errors: @loan.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # GET /api/v1/loans/:id/documents
      def documents
        return unless authorize_action!('loans', 'read')
        
        documents = @loan.documents.order(created_at: :desc)
        
        # Build base URL for file downloads
        api_host = request.base_url
        
        render json: {
          documents: documents.map do |doc|
            file_path = doc.file.attached? ? Rails.application.routes.url_helpers.rails_blob_path(doc.file, only_path: true) : nil
            {
              id: doc.id,
              name: doc.document_name || doc.file&.filename&.to_s,
              file_name: doc.file.attached? ? doc.file.filename.to_s : nil,
              category: doc.category,
              file_url: file_path ? "#{api_host}#{file_path}" : nil,
              created_at: doc.created_at
            }
          end
        }
      end

      # POST /api/v1/loans/:id/documents
      def upload_documents
        return unless authorize_action!('loans', 'update')
        
        uploaded_count = 0
        errors = []
        
        if params[:documents].present?
          params[:documents].each do |_index, doc_params|
            next unless doc_params[:file].present?
            
            document = @loan.documents.build(
              owner: @loan,
              category: doc_params[:category] || 'general',
              document_name: doc_params[:name] || doc_params[:file].original_filename,
              uploaded_by: current_user.id.to_s
            )
            
            document.file.attach(doc_params[:file])
            
            if document.save
              uploaded_count += 1
            else
              errors << document.errors.full_messages.join(', ')
            end
          end
        end
        
        if errors.any?
          render json: { error: errors.join('; '), uploaded: uploaded_count }, status: :unprocessable_entity
        else
          render json: { message: "#{uploaded_count} document(s) uploaded successfully", uploaded: uploaded_count }
        end
      end

      # DELETE /api/v1/loans/:id/documents/:document_id
      def destroy_document
        return unless authorize_action!('loans', 'update')
        
        document = @loan.documents.find_by(id: params[:document_id])
        
        unless document
          render json: { error: 'Document not found' }, status: :not_found
          return
        end
        
        if document.destroy
          render json: { message: 'Document deleted successfully' }
        else
          render json: { error: 'Failed to delete document' }, status: :unprocessable_entity
        end
      end

      private

      def set_loan
        @loan = @company.loans.find(params[:id])
        
        # RBAC: Check location access
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          if location_ids.any? && @loan.location_id.present? && !location_ids.include?(@loan.location_id)
            render json: { error: 'Not authorized to access this loan' }, status: :forbidden
            return
          end
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Loan not found' }, status: :not_found
      end

      def loan_params
        params.require(:loan).permit(
          :borrower_type,
          :borrower_id,
          :financed_entity_type,
          :financed_entity_id,
          :location_id,
          :loan_type,
          :status,
          :principal_amount,
          :current_balance,
          :interest_rate,
          :term_months,
          :payment_frequency,
          :regular_payment_amount,
          :origination_date,
          :first_payment_date,
          :origination_fee,
          :auto_pay_enabled,
          :default_payment_method_id,
          :notes,
          :internal_notes
        )
      end

      def update_params_contain_protected_fields?
        protected_fields = [:principal_amount, :interest_rate, :term_months, :current_balance]
        (loan_params.keys.map(&:to_sym) & protected_fields).any?
      end
    end
  end
end
