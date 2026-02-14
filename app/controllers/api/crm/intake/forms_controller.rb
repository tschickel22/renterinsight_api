module Api
  module Crm
    module Intake
      class FormsController < ApplicationController
        include RbacAuthorization
        rbac_resource :crm

        # Skip authentication for index/show - we'll handle both public and admin access in set_company_scope
        skip_before_action :authenticate, only: [:index, :show]
        skip_before_action :check_rbac_authorization, only: [:index, :show]
        
        before_action :set_company_scope
        before_action :set_form, only: [:show, :update, :destroy]

        def index
          # For public requests (via token), only show active forms
          # For admin requests (authenticated), show all forms
          if params[:token].present? && params[:company_id].present?
            @forms = @company.intake_forms.where(is_active: true).order(updated_at: :desc)
          else
            @forms = @company.intake_forms.order(updated_at: :desc)
          end
          
          render json: @forms.map(&:as_json)
        end
        
        # Get available CRM lead fields for mapping
        def lead_fields
          fields = [
            { name: 'first_name', label: 'First Name', type: 'text', required: true, group: 'Basic Info' },
            { name: 'last_name', label: 'Last Name', type: 'text', required: false, group: 'Basic Info' },
            { name: 'email', label: 'Email', type: 'email', required: false, group: 'Contact Info' },
            { name: 'phone', label: 'Phone', type: 'phone', required: false, group: 'Contact Info' },
            { name: 'company', label: 'Company', type: 'text', required: false, group: 'Basic Info' },
            { name: 'job_title', label: 'Job Title', type: 'text', required: false, group: 'Basic Info' },
            { name: 'street', label: 'Street Address', type: 'text', required: false, group: 'Address' },
            { name: 'city', label: 'City', type: 'text', required: false, group: 'Address' },
            { name: 'state', label: 'State', type: 'text', required: false, group: 'Address' },
            { name: 'zip', label: 'ZIP Code', type: 'text', required: false, group: 'Address' },
            { name: 'notes', label: 'Notes', type: 'textarea', required: false, group: 'Additional Info' }
          ]
          
          render json: { fields: fields }
        end

        def show
          response = @form.as_json

          # For public requests, include company locations so the form can show a location picker
          if params[:token].present? && params[:company_id].present?
            locations = @company.locations.active.order(:name)
            if locations.count > 1
              response[:company_locations] = locations.map { |l| { id: l.id, name: l.name, city: l.city, state: l.state } }
            end
          end

          render json: response
        end

        def create
          Rails.logger.info "CREATE: Received params: #{params.inspect}"
          @form = @company.intake_forms.build(form_params)
          
          if @form.save
            Rails.logger.info "CREATE: Form saved with fields: #{@form.fields.inspect}"
            render json: @form.as_json, status: :created
          else
            Rails.logger.error "CREATE: Form save failed: #{@form.errors.full_messages}"
            render json: { errors: @form.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          Rails.logger.info "UPDATE: Received params: #{params.inspect}"
          if @form.update(form_params)
            Rails.logger.info "UPDATE: Form updated with fields: #{@form.fields.inspect}"
            render json: @form.as_json
          else
            Rails.logger.error "UPDATE: Form update failed: #{@form.errors.full_messages}"
            render json: { errors: @form.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          @form.destroy
          head :no_content
        end

        def bulk
          forms_data = params[:_json] || [params]
          results = []
          errors = []
          
          forms_data.each do |form_data|
            form = if form_data[:id].present?
              @company.intake_forms.find_or_initialize_by(id: form_data[:id])
            else
              @company.intake_forms.new
            end
            
            form.assign_attributes(form_params_from_hash(form_data))
            
            if form.save
              results << form
            else
              errors << { id: form_data[:id], errors: form.errors.full_messages }
            end
          end
          
          if errors.any?
            render json: { forms: results, errors: errors }, status: :unprocessable_entity
          else
            render json: results.map(&:as_json)
          end
        end

        private

        def set_company_scope
          # Public access via token (for public inventory pages)
          if params[:token].present? && params[:company_id].present?
            Rails.logger.info "🌐 [Intake::FormsController] Public access via token"
            
            company = ::Company.find_by(id: params[:company_id])
            if company.nil?
              Rails.logger.error "🚫 [Intake::FormsController] Company #{params[:company_id]} not found"
              render json: { error: 'Company not found' }, status: :not_found
              return
            end
            
            # Verify token matches company's public inventory token
            if company.public_inventory_token != params[:token]
              Rails.logger.error "🚫 [Intake::FormsController] Invalid token for company #{company.id}"
              render json: { error: 'Invalid token' }, status: :unauthorized
              return
            end
            
            @company = company
            Rails.logger.info "✅ [Intake::FormsController] Public company scope set: #{@company.name} (ID: #{@company.id})"
            return
          end
          
          # Admin access - manually authenticate from Authorization header
          Rails.logger.info "🔐 [Intake::FormsController] Admin access - authenticating from header"
          
          # Extract and validate JWT token
          header = request.headers['Authorization']
          
          unless header.present?
            Rails.logger.error "🚫 [Intake::FormsController] No authorization header present"
            render json: { error: 'Authentication required' }, status: :unauthorized
            return
          end
          
          token = header.split(' ').last
          decoded = JsonWebToken.decode(token)
          
          unless decoded
            Rails.logger.error "🚫 [Intake::FormsController] JWT decode failed"
            render json: { error: 'Invalid or expired token' }, status: :unauthorized
            return
          end
          
          # Set user ID from JWT
          @current_user_id = decoded[:user_id]
          @current_company_id = decoded[:company_id] || request.headers['X-Company-Id']&.to_i
          
          # Get current user
          user = User.find_by(id: @current_user_id)
          unless user
            Rails.logger.error "🚫 [Intake::FormsController] User #{@current_user_id} not found"
            render json: { error: 'User not found' }, status: :unauthorized
            return
          end
          
          @current_user = user
          
          # Get company ID (with platform admin override)
          company_id = if user.role.in?(['platform_admin', 'tenant', 'super_admin', 'admin'])
            context_company_id = request.headers['X-Company-ID']&.to_i || request.headers['X-Company-Context']&.to_i
            if context_company_id.present? && context_company_id > 0
              Rails.logger.info "✅ [Intake::FormsController] Platform admin #{user.email} switching to company #{context_company_id}"
              context_company_id
            else
              @current_company_id || user.company_id
            end
          else
            @current_company_id || user.company_id
          end
          
          unless company_id.present?
            Rails.logger.error "🚫 [Intake::FormsController] No company context available"
            render json: { error: 'No company context' }, status: :forbidden
            return
          end
          
          @company = ::Company.find_by(id: company_id)
          
          if @company.nil?
            Rails.logger.error "🚫 [Intake::FormsController] Company #{company_id} not found"
            render json: { error: 'Company not found' }, status: :not_found
            return
          end
          
          Rails.logger.info "✅ [Intake::FormsController] Admin company scope set: #{@company.name} (ID: #{@company.id}) for user #{user.email}"
        end

        def set_form
          @form = @company.intake_forms.find_by(id: params[:id])
          unless @form
            render json: { error: 'Form not found or access denied' }, status: :not_found
            return
          end
        end

        def form_params
          params.require(:intake_form).permit(
            :name, :description, :source_id, :is_active, :isActive,
            :thank_you_message, :redirect_url, :submit_button_text,
            :notified_user_id, :auto_create_lead, :auto_create_activity,
            field_mappings: {},
            fields: [:id, :name, :label, :type, :required, :placeholder, :order, :isActive, :leadField, options: []]
          ).tap do |p|
            # Normalize isActive to is_active for Rails
            if p.key?(:isActive)
              p[:is_active] = p.delete(:isActive)
            end
            
            # Ensure fields is set (will be saved to schema column via model)
            p[:fields] ||= []
            
            # Build field_mappings from fields if not provided
            if p[:field_mappings].blank? && p[:fields].present?
              mappings = {}
              p[:fields].each do |field|
                if field[:leadField].present?
                  mappings[field[:name]] = field[:leadField]
                end
              end
              p[:field_mappings] = mappings
            end
            
            # CRITICAL: Permit the constructed field_mappings hash
            p[:field_mappings] = p[:field_mappings].permit! if p[:field_mappings].is_a?(ActionController::Parameters)
            
            # Log for debugging
            Rails.logger.info "Form params: #{p.inspect}"
          end
        end
        
        def form_params_from_hash(hash)
          hash.permit(
            :name, :description, :source_id, :sourceId, :is_active, :isActive,
            :thank_you_message, :redirect_url, :submit_button_text,
            fields: [:id, :name, :label, :type, :required, :placeholder, :order, :isActive, options: []]
          ).tap do |p|
            p[:source_id] = hash[:sourceId] if hash[:sourceId].present? && p[:source_id].blank?
            p[:is_active] = hash[:isActive] if hash.key?(:isActive) && !hash.key?(:is_active)
          end
        end
      end
    end
  end
end
