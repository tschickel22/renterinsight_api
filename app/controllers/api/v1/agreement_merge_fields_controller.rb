module Api
  module V1
    class AgreementMergeFieldsController < ApplicationController
      before_action :set_company_scope
      before_action :load_entities

      # GET /api/v1/agreement_merge_fields
      def index
        return unless authorize_action!('agreements', 'read')

        render json: { merge_fields: merge_field_definitions }
      end

      private

      def load_entities
        @contact = nil
        @account = nil
        @deal = nil

        begin
          @contact = @company.contacts.find_by(id: params[:contact_id]) if params[:contact_id].present?
        rescue => e
          Rails.logger.error("[AgreementMergeFields] Contact lookup failed: #{e.message}")
        end

        begin
          @account = @company.accounts.find_by(id: params[:account_id]) if params[:account_id].present?
        rescue => e
          Rails.logger.error("[AgreementMergeFields] Account lookup failed: #{e.message}")
        end

        begin
          @deal = @company.deals.find_by(id: params[:deal_id]) if params[:deal_id].present?
        rescue => e
          Rails.logger.error("[AgreementMergeFields] Deal lookup failed: #{e.message}")
        end
      end

      def merge_field_definitions
        {
          contact: {
            available: @contact.present?,
            fields: [
              { key: 'contact.first_name', label: 'First Name', type: 'text', value: @contact&.first_name },
              { key: 'contact.last_name', label: 'Last Name', type: 'text', value: @contact&.last_name },
              { key: 'contact.full_name', label: 'Full Name', type: 'text', value: @contact ? [@contact.first_name, @contact.last_name].compact.join(' ').presence : nil },
              { key: 'contact.email', label: 'Email', type: 'text', value: @contact&.email },
              { key: 'contact.phone', label: 'Phone', type: 'text', value: @contact&.phone },
              { key: 'contact.title', label: 'Title', type: 'text', value: @contact.respond_to?(:title) ? @contact.title : nil },
              { key: 'contact.company_name', label: 'Company Name', type: 'text', value: @contact ? (@contact.respond_to?(:company_name) ? @contact.company_name : @contact.account&.name) : nil }
            ]
          },
          account: {
            available: @account.present?,
            fields: [
              { key: 'account.name', label: 'Account Name', type: 'text', value: @account&.name },
              { key: 'account.email', label: 'Account Email', type: 'text', value: @account.respond_to?(:email) ? @account.email : nil },
              { key: 'account.phone', label: 'Account Phone', type: 'text', value: @account.respond_to?(:phone) ? @account.phone : nil },
              { key: 'account.website', label: 'Website', type: 'text', value: @account.respond_to?(:website) ? @account.website : nil },
              { key: 'account.address', label: 'Address', type: 'text', value: @account ? [@account.try(:street), @account.try(:city), @account.try(:state), @account.try(:zip)].compact.join(', ').presence : nil },
              { key: 'account.city', label: 'City', type: 'text', value: @account.try(:city) },
              { key: 'account.state', label: 'State', type: 'text', value: @account.try(:state) },
              { key: 'account.zip', label: 'ZIP Code', type: 'text', value: @account.try(:zip) },
              { key: 'account.industry', label: 'Industry', type: 'text', value: @account.try(:industry) }
            ]
          },
          deal: {
            available: @deal.present?,
            fields: [
              { key: 'deal.name', label: 'Deal Name', type: 'text', value: @deal ? (@deal.respond_to?(:title) ? @deal.title : @deal.name) : nil },
              { key: 'deal.amount', label: 'Deal Amount', type: 'currency', value: @deal ? (@deal.respond_to?(:amount) ? @deal.amount : @deal.try(:value)) : nil },
              { key: 'deal.stage', label: 'Deal Stage', type: 'text', value: @deal.respond_to?(:stage) ? @deal.stage : nil },
              { key: 'deal.close_date', label: 'Expected Close Date', type: 'date', value: @deal ? (@deal.respond_to?(:expected_close_date) ? @deal.expected_close_date : @deal.try(:close_date)) : nil },
              { key: 'deal.probability', label: 'Probability', type: 'text', value: @deal.respond_to?(:probability) ? @deal.probability : nil }
            ]
          },
          company: {
            available: true,
            fields: [
              { key: 'company.name', label: 'Company Name', type: 'text', value: @company.name },
              { key: 'company.email', label: 'Company Email', type: 'text', value: @company.respond_to?(:email) ? @company.email : nil },
              { key: 'company.phone', label: 'Company Phone', type: 'text', value: @company.respond_to?(:phone) ? @company.phone : nil },
              { key: 'company.website', label: 'Company Website', type: 'text', value: @company.respond_to?(:website) ? @company.website : nil },
              { key: 'company.address', label: 'Company Address', type: 'text', value: [@company.try(:street), @company.try(:city), @company.try(:state), @company.try(:zip)].compact.join(', ').presence }
            ]
          },
          date: {
            available: true,
            fields: [
              { key: 'date.today', label: "Today's Date", type: 'date', value: Date.today.strftime('%m/%d/%Y') },
              { key: 'date.current_year', label: 'Current Year', type: 'text', value: Date.today.year.to_s },
              { key: 'date.current_month', label: 'Current Month', type: 'text', value: Date.today.strftime('%B') }
            ]
          },
          agreement: {
            available: true,
            fields: [
              { key: 'agreement.number', label: 'Agreement Number', type: 'text', value: nil },
              { key: 'agreement.title', label: 'Title', type: 'text', value: nil },
              { key: 'agreement.date', label: 'Agreement Date', type: 'date', value: nil },
              { key: 'agreement.expiry_date', label: 'Expiry Date', type: 'date', value: nil }
            ]
          },
          signer: {
            available: true,
            fields: [
              { key: 'signer.name', label: 'Signer Name', type: 'text', value: nil },
              { key: 'signer.email', label: 'Signer Email', type: 'text', value: nil },
              { key: 'signer.signature', label: 'Signature', type: 'signature', value: nil },
              { key: 'signer.initials', label: 'Initials', type: 'initials', value: nil },
              { key: 'signer.signed_date', label: 'Date Signed', type: 'date', value: nil }
            ]
          },
          custom: {
            available: true,
            fields: [
              { key: 'custom.text_field', label: 'Custom Text', type: 'text_input', value: nil },
              { key: 'custom.date_field', label: 'Custom Date', type: 'date_input', value: nil },
              { key: 'custom.checkbox', label: 'Custom Checkbox', type: 'checkbox', value: nil }
            ]
          }
        }
      end
    end
  end
end
