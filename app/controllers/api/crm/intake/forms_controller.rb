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
        
        # Get available CRM lead fields for mapping.
        #
        # The standard columns below are the same for every tenant. The custom
        # fields are not: a dealer who collects "Are you wanting to finance or
        # buy in cash?" on their intake form had nowhere to map the answer, so
        # it only ever survived as free text in the lead's notes and no report
        # could ever see it. Evangeline alone has 28 lead custom fields that
        # this list never offered.
        def lead_fields
          standard = [
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

          # Namespaced with `custom:` because a custom field key is free to
          # collide with a real Lead column — company 17 has a lead custom
          # field keyed `email` — and an unprefixed collision would quietly
          # shadow the standard mapping with whichever entry the UI listed
          # last. The prefix is also what tells IntakeSubmission to write the
          # answer into custom_field_values instead of an attribute.
          custom = @company.custom_fields
                           .where(module: 'leads', is_active: true)
                           .map do |cf|
            {
              name: "#{IntakeForm::CUSTOM_FIELD_PREFIX}#{cf.field_key}",
              label: cf.label.presence || cf.name.presence || cf.field_key.to_s.humanize,
              type: cf.field_type,
              required: !!cf.required,
              group: 'Custom Fields'
            }
          end

          # Sorted by label within each group so a 28-entry list is scannable.
          # The standard block keeps its hand-ordered shape (first name before
          # last name, street before city), which alphabetising would scramble.
          render json: { fields: standard + custom.sort_by { |f| f[:label].to_s.downcase } }
        end

        def show
          response = @form.as_json

          # For public requests, include company locations so the form can show
          # a location picker — but only when the form isn't already bound to
          # a specific location (admin's choice wins; no need to ask the
          # visitor) and the company has more than one active location.
          if params[:token].present? && params[:company_id].present? && @form.location_id.blank?
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
            :notified_user_id, :location_id, :locationId,
            :auto_create_lead, :auto_create_activity,
            :captcha_required, :captchaRequired,
            field_mappings: {},
            fields: [
              :id, :name, :label, :type, :required, :placeholder, :order, :isActive, :leadField,
              :helpText, :helpTextPosition, :consentText, :width,
              options: [],
              leadFieldMap: [:street, :street2, :city, :state, :zip]
            ]
          ).tap do |p|
            # Normalize isActive → is_active. The FE spreads ...formData (which
            # still carries the camelCase copy) AND emits the fresh snake_case
            # value, so both keys land here. Prefer snake_case — the camelCase
            # copy is a stale echo of what came back from as_json. Same tap
            # pattern as captcha_required below (added after edits to those
            # fields silently reverted because the tap overwrote the new
            # value with the old one).
            if p.key?(:is_active)
              p.delete(:isActive)
            elsif p.key?(:isActive)
              p[:is_active] = p.delete(:isActive)
            end
            if p.key?(:location_id)
              p.delete(:locationId)
            elsif p.key?(:locationId)
              p[:location_id] = p.delete(:locationId)
            end
            # Blank string from an "Any location" dropdown option becomes nil
            # so the form clears its binding cleanly and re-enters the
            # Corporate-fallback path on submission.
            p[:location_id] = nil if p[:location_id].is_a?(String) && p[:location_id].strip.empty?

            # Accept camelCase captchaRequired from the FE, coerce to boolean.
            # When BOTH keys arrive (the FE spreads formData AND explicitly
            # writes snake_case), the snake_case value is authoritative — the
            # camelCase copy is usually a stale echo of what came back from
            # as_json. Prefer snake_case; drop the camelCase duplicate.
            if p.key?(:captcha_required)
              p.delete(:captchaRequired)
            elsif p.key?(:captchaRequired)
              p[:captcha_required] = p.delete(:captchaRequired)
            end
            if p.key?(:captcha_required)
              p[:captcha_required] = ActiveModel::Type::Boolean.new.cast(p[:captcha_required])
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
            :captcha_required, :captchaRequired,
            fields: [
              :id, :name, :label, :type, :required, :placeholder, :order, :isActive, :leadField,
              :helpText, :helpTextPosition, :consentText, :width,
              options: [],
              leadFieldMap: [:street, :street2, :city, :state, :zip]
            ]
          ).tap do |p|
            p[:source_id] = hash[:sourceId] if hash[:sourceId].present? && p[:source_id].blank?
            p[:is_active] = hash[:isActive] if hash.key?(:isActive) && !hash.key?(:is_active)
            if p.key?(:captcha_required)
              p.delete(:captchaRequired)
            elsif p.key?(:captchaRequired)
              p[:captcha_required] = p.delete(:captchaRequired)
            end
            if p.key?(:captcha_required)
              p[:captcha_required] = ActiveModel::Type::Boolean.new.cast(p[:captcha_required])
            end
          end
        end
      end
    end
  end
end
