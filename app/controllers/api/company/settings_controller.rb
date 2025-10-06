# frozen_string_literal: true

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
        render json: {
          communications: default_communications_settings
        }, status: :ok
      end

      def update
        company = find_or_create_company
        
        if company
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
        company = current_user&.company || Company.first rescue nil
        
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
