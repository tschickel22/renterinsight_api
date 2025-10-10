module Api
  module Crm
    module Intake
      class FormsController < ApplicationController
        before_action :set_company
        before_action :set_form, only: [:show, :update, :destroy]

        def index
          @forms = @company.intake_forms.order(updated_at: :desc)
          render json: @forms.map(&:as_json)
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

        def set_company
          @company = ::Company.find(current_company_id)
        rescue ActiveRecord::RecordNotFound
          render json: { error: 'Company not found' }, status: :not_found
        end

        def set_form
          @form = @company.intake_forms.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: 'Form not found' }, status: :not_found
        end

        def form_params
          params.require(:intake_form).permit(
            :name, :description, :source_id, :is_active, :isActive,
            :thank_you_message, :redirect_url, :submit_button_text,
            fields: [:id, :name, :label, :type, :required, :placeholder, :order, :isActive, options: []]
          ).tap do |p|
            # Normalize isActive to is_active for Rails
            if p.key?(:isActive)
              p[:is_active] = p.delete(:isActive)
            end
            
            # Ensure fields is set (will be saved to schema column via model)
            p[:fields] ||= []
            
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
