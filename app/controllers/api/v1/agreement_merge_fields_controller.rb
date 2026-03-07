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

        begin
          if @deal.present?
            @vehicle = nil
            if @deal.respond_to?(:vehicle_id) && @deal.vehicle_id.present?
              @vehicle = @company.vehicles.find_by(id: @deal.vehicle_id)
            end
            if @vehicle.nil? && @deal.respond_to?(:deal_line_items)
              vehicle_item = @deal.deal_line_items
                                  .where(is_deleted: [false, nil])
                                  .where(category: ['home', 'vehicle', 'unit', 'rv'])
                                  .first
              if vehicle_item&.respond_to?(:vehicle_id) && vehicle_item.vehicle_id.present?
                @vehicle = @company.vehicles.find_by(id: vehicle_item.vehicle_id)
              end
            end
          end
        rescue => e
          Rails.logger.error("[AgreementMergeFields] Vehicle lookup failed: #{e.message}")
        end

        begin
          if params[:invoice_id].present?
            @invoice = @company.invoices.find_by(id: params[:invoice_id])
          elsif @deal.present?
            # Auto-detect invoice with draw schedule from linked deal
            @invoice = @company.invoices.where(deal_id: @deal.id)
                                        .where.not(draw_schedule: [nil, {}])
                                        .order(created_at: :desc).first
            @invoice ||= @company.invoices.where(deal_id: @deal.id).order(created_at: :desc).first
          end
        rescue => e
          Rails.logger.error("[AgreementMergeFields] Invoice lookup failed: #{e.message}")
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
              { key: 'contact.company_name', label: 'Company Name', type: 'text', value: @contact ? (@contact.respond_to?(:company_name) ? @contact.company_name : @contact.account&.name) : nil },
              { key: 'contact.street', label: 'Street Address', type: 'text', value: @contact.try(:street) || @contact.try(:address) },
              { key: 'contact.city', label: 'City', type: 'text', value: @contact.try(:city) },
              { key: 'contact.state', label: 'State', type: 'text', value: @contact.try(:state) },
              { key: 'contact.zip', label: 'ZIP Code', type: 'text', value: @contact.try(:zip) || @contact.try(:postal_code) },
              { key: 'contact.mobile_phone', label: 'Mobile Phone', type: 'text', value: @contact.try(:mobile_phone) || @contact.try(:cell_phone) }
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
              { key: 'deal.probability', label: 'Probability', type: 'text', value: @deal.respond_to?(:probability) ? @deal.probability : nil },
              { key: 'deal.owner_name', label: 'Sales Person', type: 'text', value: @deal ? (@deal.respond_to?(:owner) ? [@deal.owner&.first_name, @deal.owner&.last_name].compact.join(' ').presence : @deal.try(:assigned_to_name)) : nil }
            ]
          },
          vehicle: {
            available: @vehicle.present?,
            fields: [
              { key: 'vehicle.make', label: 'Make', type: 'text', value: @vehicle.try(:make) },
              { key: 'vehicle.model', label: 'Model', type: 'text', value: @vehicle.try(:model) },
              { key: 'vehicle.year', label: 'Year', type: 'text', value: @vehicle.try(:year)&.to_s },
              { key: 'vehicle.vin', label: 'VIN / Serial Number', type: 'text', value: @vehicle.try(:vin) || @vehicle.try(:serial_number) },
              { key: 'vehicle.stock_number', label: 'Stock Number', type: 'text', value: @vehicle.try(:stock_number) },
              { key: 'vehicle.condition', label: 'New/Used', type: 'text', value: @vehicle.try(:condition)&.titleize },
              { key: 'vehicle.sections', label: 'Sections (Single/Double)', type: 'text', value: @vehicle.try(:sections) },
              { key: 'vehicle.bedrooms', label: 'Bedrooms', type: 'text', value: @vehicle.try(:bedrooms)&.to_s },
              { key: 'vehicle.bathrooms', label: 'Bathrooms', type: 'text', value: @vehicle.try(:bathrooms)&.to_s || @vehicle.try(:baths)&.to_s },
              { key: 'vehicle.length', label: 'Length', type: 'text', value: @vehicle.try(:length)&.to_s },
              { key: 'vehicle.width', label: 'Width', type: 'text', value: @vehicle.try(:width)&.to_s },
              { key: 'vehicle.exterior_color', label: 'Exterior Color', type: 'text', value: @vehicle.try(:exterior_color) || @vehicle.try(:color) },
              { key: 'vehicle.interior_color', label: 'Interior Color', type: 'text', value: @vehicle.try(:interior_color) },
              { key: 'vehicle.price', label: 'Price', type: 'currency', value: @vehicle.try(:price) || @vehicle.try(:msrp) || @vehicle.try(:sale_price) }
            ]
          },
          invoice: {
            available: @invoice.present?,
            fields: [
              { key: 'invoice.number', label: 'Invoice Number', type: 'text', value: @invoice&.invoice_number },
              { key: 'invoice.date', label: 'Invoice Date', type: 'date', value: @invoice&.invoice_date&.strftime('%m/%d/%Y') },
              { key: 'invoice.due_date', label: 'Due Date', type: 'date', value: @invoice&.due_date&.strftime('%m/%d/%Y') },
              { key: 'invoice.total', label: 'Total', type: 'currency', value: @invoice&.total },
              { key: 'invoice.amount_due', label: 'Amount Due', type: 'currency', value: @invoice&.amount_due },
              { key: 'invoice.draw_schedule_text', label: 'Draw Schedule', type: 'text', value: @invoice ? format_draw_schedule(@invoice) : nil }
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

      def format_draw_schedule(invoice)
        return nil unless invoice.draw_schedule.present? && invoice.draw_schedule['draws'].present?

        draws = invoice.draw_schedule['draws'].sort_by { |d| d['position'] || 0 }
        template_name = invoice.draw_schedule['template_name']
        h = ActionController::Base.helpers

        lines = []
        lines << "Payment Draw Schedule#{template_name.present? ? " (#{template_name})" : ''}"
        lines << "Invoice: #{invoice.invoice_number} | Total: #{h.number_to_currency(invoice.total)}"
        lines << ''

        draws.each_with_index do |draw, i|
          pct = "#{draw['percentage']}%"
          amt = h.number_to_currency(draw['amount'])
          desc = draw['description'] || "Draw #{i + 1}"
          lines << "Draw #{i + 1}: #{pct} - #{desc} - #{amt}"
        end

        lines.join("\n")
      end
    end
  end
end
