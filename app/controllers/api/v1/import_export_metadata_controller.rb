# frozen_string_literal: true

require 'csv'

module Api
  module V1
    class ImportExportMetadataController < ApplicationController
      before_action :set_company_scope

      # GET /api/v1/import_export/modules
      def modules
        return unless authorize_action!('data_import_export', 'read')
        items = ImportExport::ModuleRegistry.available_modules.map do |m|
          m.merge(
            requires_context: ImportExport::ModuleRegistry.requires_context?(m[:key]),
            context_params:   ImportExport::ModuleRegistry.context_params(m[:key])
          )
        end
        render json: { modules: items }
      end

      # GET /api/v1/import_export/modules/:module_type/fields
      # Pass ?context=import to exclude FK _id columns (not useful in CSV imports)
      def fields
        return unless authorize_action!('data_import_export', 'read')

        cfg = ImportExport::ModuleRegistry.config_for(params[:module_type])
        return render json: { error: 'Unknown module' }, status: :not_found unless cfg

        for_import = params[:context].to_s == 'import'
        fields = ImportExport::ModuleRegistry.fields_for(params[:module_type], company_id: @company.id, for_import: for_import)
        render json: {
          module_type: params[:module_type],
          label: cfg[:label],
          match_fields: cfg[:match_fields],
          supports_images: ImportExport::ModuleRegistry.supports_images?(params[:module_type]),
          fields: fields
        }
      end

      # GET /api/v1/import_export/modules/:module_type/sample_csv
      def sample_csv
        return unless authorize_action!('data_import_export', 'read')

        cfg = ImportExport::ModuleRegistry.config_for(params[:module_type])
        return render json: { error: 'Unknown module' }, status: :not_found unless cfg

        csv_data = if params[:module_type].to_s == 'budget_lines'
                     generate_budget_lines_sample_csv
                   else
                     generate_default_sample_csv(params[:module_type])
                   end

        send_data csv_data,
                  type: 'text/csv',
                  filename: "#{params[:module_type]}_template.csv"
      end

      private

      def generate_default_sample_csv(module_type)
        fields = ImportExport::ModuleRegistry.fields_for(module_type, company_id: @company.id, for_import: true)
        CSV.generate do |csv|
          csv << fields.map { |f| f[:required] ? "#{f[:label]} *" : f[:label] }
          csv << fields.map { |_| '' }
        end
      end

      # Budget Lines uses a fixed dealer-friendly layout:
      # Account Number, Account Name, Jan..Dec, Notes
      #
      # variant=sample  → ~20 standard MH dealer accounts with realistic sample amounts
      # variant=all     → every active non-header account in the company's COA, blank amounts
      def generate_budget_lines_sample_csv
        variant = params[:variant].to_s

        headers = ['Account Number', 'Account Name',
                   'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                   'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
                   'Notes']

        if variant == 'all'
          # All company accounts — blank amounts for the dealer to fill in
          accounts = @company.chart_of_accounts
                            .where(is_active: true, is_header: false)
                            .order(:account_number)

          CSV.generate do |csv|
            csv << headers
            accounts.each do |acct|
              csv << [acct.account_number, acct.name,
                      '', '', '', '', '', '',
                      '', '', '', '', '', '',
                      '']
            end
          end
        else
          # Sample template with ~20 standard manufactured housing accounts and realistic amounts
          CSV.generate do |csv|
            csv << headers
            sample_mh_accounts.each do |row|
              csv << row
            end
          end
        end
      end

      # Standard manufactured housing dealer accounts with seasonal amounts
      def sample_mh_accounts
        [
          ['4000', 'Home Sales - New',           '180000','150000','200000','220000','250000','240000','230000','210000','190000','170000','160000','140000', 'New home sales revenue'],
          ['4100', 'Home Sales - Used',           '45000','38000','50000','55000','62000','60000','57000','52000','48000','42000','40000','35000', 'Used/pre-owned home sales'],
          ['4200', 'Finance & Insurance Revenue',  '12000','10000','14000','15000','17000','16000','15000','14000','13000','11000','10000','9000', 'F&I product revenue'],
          ['4300', 'Service Revenue',              '8000','7500','8500','9000','9500','10000','10000','9500','9000','8500','8000','7000', 'Service department revenue'],
          ['4400', 'Parts Revenue',                '5000','4500','5500','6000','6500','7000','7000','6500','6000','5500','5000','4000', 'Parts sales'],
          ['4500', 'Delivery & Setup Fees',        '3000','2500','3500','4000','4500','4500','4000','3500','3000','2500','2500','2000', 'Delivery and setup charges'],
          ['5000', 'Cost of Homes Sold - New',     '135000','112500','150000','165000','187500','180000','172500','157500','142500','127500','120000','105000', 'COGS for new homes'],
          ['5100', 'Cost of Homes Sold - Used',    '30000','25000','33000','36000','41000','40000','38000','35000','32000','28000','27000','23000', 'COGS for used homes'],
          ['5200', 'Setup & Delivery Costs',       '4000','3500','4500','5000','5500','5500','5000','4500','4000','3500','3500','3000', 'Installation & delivery labor/materials'],
          ['5300', 'Parts Cost of Goods Sold',     '2500','2200','2800','3000','3300','3500','3500','3200','3000','2700','2500','2000', 'Cost of parts sold'],
          ['6000', 'Salaries & Wages',             '35000','35000','35000','35000','35000','35000','35000','35000','35000','35000','35000','35000', 'Employee compensation'],
          ['6100', 'Sales Commissions',            '15000','12500','16500','18000','20500','19500','18500','17000','15500','14000','13000','11000', 'Sales team commissions'],
          ['6200', 'Employee Benefits',            '8000','8000','8000','8000','8000','8000','8000','8000','8000','8000','8000','8000', 'Health insurance, 401k, etc.'],
          ['6300', 'Rent / Lot Lease',             '12000','12000','12000','12000','12000','12000','12000','12000','12000','12000','12000','12000', 'Dealership lot rent'],
          ['6400', 'Utilities',                    '2500','2500','2200','2000','2000','2500','3000','3000','2500','2200','2300','2500', 'Electric, water, gas, internet'],
          ['6500', 'Insurance',                    '3500','3500','3500','3500','3500','3500','3500','3500','3500','3500','3500','3500', 'Business insurance premiums'],
          ['6600', 'Advertising & Marketing',      '5000','5000','6000','7000','7000','6000','5000','5000','4000','4000','5000','6000', 'Marketing spend'],
          ['6700', 'Office Supplies & Expenses',   '800','800','800','800','800','800','800','800','800','800','800','800', 'General office expenses'],
          ['6800', 'Professional Fees',            '1500','1500','1500','1500','1500','1500','1500','1500','1500','1500','1500','1500', 'Legal, accounting, consulting'],
          ['6900', 'Floor Plan Interest',          '4000','3800','4200','4500','5000','5000','4800','4500','4200','3800','3500','3200', 'Inventory financing interest'],
          ['7000', 'Depreciation & Amortization',  '2000','2000','2000','2000','2000','2000','2000','2000','2000','2000','2000','2000', 'Fixed asset depreciation'],
        ]
      end
    end
  end
end
