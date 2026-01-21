module Api
  module Crm
    module Intake
      class FormsController < ApplicationController
        include RbacAuthorization
        rbac_resource :crm

        before_action :set_company_scope
        before_action :set_form, only: [:show, :update, :destroy]

        def index
          @forms = @company.intake_forms.order(updated_at: :desc)
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
          render json: @form.as_json
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
          unless current_user
            Rails.logger.error "🚫 [Intake::FormsController] No authenticated user found"
            render json: { error: 'Authentication required' }, status: :unauthorized
            return
          end
          
          company_id = current_company_id
          
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
          
          Rails.logger.info "✅ [Intake::FormsController] Company scope set: #{@company.name} (ID: #{@company.id})"
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
