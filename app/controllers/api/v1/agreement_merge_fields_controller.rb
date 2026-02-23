module Api
  module V1
    class AgreementMergeFieldsController < ApplicationController
      before_action :set_company_scope

      # GET /api/v1/agreement_merge_fields
      def index
        return unless authorize_action!('agreements', 'read')

        render json: { merge_fields: merge_field_definitions }
      end

      private

      def set_company_scope
        unless current_user
          return render json: { error: 'Authentication required' }, status: :unauthorized
        end

        @company = Company.find_by(id: current_company_id)
        unless @company
          return render json: { error: 'Company not found' }, status: :not_found
        end
      end

      def merge_field_definitions
        {
          contact: [
            { key: 'contact.first_name', label: 'First Name', type: 'text' },
            { key: 'contact.last_name', label: 'Last Name', type: 'text' },
            { key: 'contact.full_name', label: 'Full Name', type: 'text' },
            { key: 'contact.email', label: 'Email', type: 'text' },
            { key: 'contact.phone', label: 'Phone', type: 'text' },
            { key: 'contact.title', label: 'Title', type: 'text' },
            { key: 'contact.department', label: 'Department', type: 'text' }
          ],
          company: [
            { key: 'company.name', label: 'Company Name', type: 'text' },
            { key: 'company.phone', label: 'Company Phone', type: 'text' },
            { key: 'company.email', label: 'Company Email', type: 'text' },
            { key: 'company.address', label: 'Company Address', type: 'text' }
          ],
          location: [
            { key: 'location.name', label: 'Location Name', type: 'text' },
            { key: 'location.address', label: 'Location Address', type: 'text' },
            { key: 'location.phone', label: 'Location Phone', type: 'text' },
            { key: 'location.email', label: 'Location Email', type: 'text' }
          ],
          vehicle: [
            { key: 'vehicle.stock_number', label: 'Stock Number', type: 'text' },
            { key: 'vehicle.vin', label: 'VIN', type: 'text' },
            { key: 'vehicle.year', label: 'Year', type: 'text' },
            { key: 'vehicle.make', label: 'Make', type: 'text' },
            { key: 'vehicle.model', label: 'Model', type: 'text' },
            { key: 'vehicle.trim', label: 'Trim', type: 'text' },
            { key: 'vehicle.color', label: 'Color', type: 'text' },
            { key: 'vehicle.mileage', label: 'Mileage', type: 'text' },
            { key: 'vehicle.price', label: 'Price', type: 'currency' }
          ],
          property: [
            { key: 'property.name', label: 'Property Name', type: 'text' },
            { key: 'property.address', label: 'Property Address', type: 'text' },
            { key: 'property.city', label: 'City', type: 'text' },
            { key: 'property.state', label: 'State', type: 'text' },
            { key: 'property.zip', label: 'ZIP Code', type: 'text' }
          ],
          quote: [
            { key: 'quote.number', label: 'Quote Number', type: 'text' },
            { key: 'quote.total', label: 'Quote Total', type: 'currency' },
            { key: 'quote.date', label: 'Quote Date', type: 'date' },
            { key: 'quote.expiry_date', label: 'Expiry Date', type: 'date' }
          ],
          deal: [
            { key: 'deal.name', label: 'Deal Name', type: 'text' },
            { key: 'deal.amount', label: 'Deal Amount', type: 'currency' },
            { key: 'deal.stage', label: 'Deal Stage', type: 'text' },
            { key: 'deal.close_date', label: 'Expected Close Date', type: 'date' }
          ],
          account: [
            { key: 'account.name', label: 'Account Name', type: 'text' },
            { key: 'account.industry', label: 'Industry', type: 'text' },
            { key: 'account.phone', label: 'Account Phone', type: 'text' },
            { key: 'account.website', label: 'Website', type: 'text' }
          ],
          lease: [
            { key: 'lease.start_date', label: 'Lease Start Date', type: 'date' },
            { key: 'lease.end_date', label: 'Lease End Date', type: 'date' },
            { key: 'lease.monthly_rent', label: 'Monthly Rent', type: 'currency' },
            { key: 'lease.deposit', label: 'Security Deposit', type: 'currency' }
          ],
          signer: [
            { key: 'signer.name', label: 'Signer Name', type: 'text' },
            { key: 'signer.email', label: 'Signer Email', type: 'text' },
            { key: 'signer.signature', label: 'Signature', type: 'signature' },
            { key: 'signer.initials', label: 'Initials', type: 'initials' },
            { key: 'signer.signed_date', label: 'Date Signed', type: 'date' }
          ],
          agreement: [
            { key: 'agreement.number', label: 'Agreement Number', type: 'text' },
            { key: 'agreement.title', label: 'Title', type: 'text' },
            { key: 'agreement.date', label: 'Agreement Date', type: 'date' },
            { key: 'agreement.expiry_date', label: 'Expiry Date', type: 'date' }
          ],
          custom: [
            { key: 'custom.text_field', label: 'Custom Text', type: 'text_input' },
            { key: 'custom.date_field', label: 'Custom Date', type: 'date_input' },
            { key: 'custom.checkbox', label: 'Custom Checkbox', type: 'checkbox' }
          ]
        }
      end
    end
  end
end
