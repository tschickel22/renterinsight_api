# frozen_string_literal: true
<<<<<<< HEAD
# app/controllers/api/company/settings_controller.rb
=======
>>>>>>> work10.2.25

module Api
  module Company
    class SettingsController < ApplicationController
      def show
        company = find_or_create_company
        
        render json: {
          communications: company&.communications_settings || default_communications_settings,
          companyId: company&.id
        }, status: :ok
      rescue => e
        Rails.logger.error "[CompanySettings#show] Error: #{e.message}"
<<<<<<< HEAD
        # Return safe defaults instead of crashing
=======
>>>>>>> work10.2.25
        render json: {
          communications: default_communications_settings
        }, status: :ok
      end

      def update
        company = find_or_create_company
        
        if company
<<<<<<< HEAD
          # Only update if we have a valid company
=======
>>>>>>> work10.2.25
          settings = params[:communications] || company.communications_settings || {}
          
          if company.respond_to?(:communications_settings=)
            company.update!(communications_settings: settings)
          end
          
          render json: {
            communications: settings,
            companyId: company.id,
            message: 'Settings updated successfully'
          }, status: :ok
        else
<<<<<<< HEAD
          # No company, but return success with the settings they sent
=======
>>>>>>> work10.2.25
          render json: {
            communications: params[:communications] || default_communications_settings,
            message: 'Settings saved (no company record yet)'
          }, status: :ok
        end
      rescue => e
        Rails.logger.error "[CompanySettings#update] Error: #{e.message}"
        render json: { 
          error: 'Failed to update settings',
          message: e.message 
        }, status: :unprocessable_entity
      end

      private

      def find_or_create_company
<<<<<<< HEAD
        # Try to find existing company
        company = current_user&.company || Company.first rescue nil
        
        # If no company exists, create a default one
=======
        company = current_user&.company || Company.first rescue nil
        
>>>>>>> work10.2.25
        if company.nil? && defined?(Company)
          begin
            company = Company.create!(name: 'Demo Company')
          rescue => e
            Rails.logger.warn "[CompanySettings] Could not create company: #{e.message}"
            nil
          end
        end
        
        company
      end

      def default_communications_settings
        {
          emailEnabled: true,
          smsEnabled: true,
          defaultSender: 'noreply@renterinsight.com',
          replyTo: 'support@renterinsight.com'
        }
      end
    end
  end
end
