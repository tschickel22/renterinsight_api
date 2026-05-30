# frozen_string_literal: true

require 'prawn'
require 'prawn/table'
require 'net/http'
require 'stringio'

module DealDesk
  # The customer-facing "pencil" — a branded one-page deal summary generated from the
  # SELECTED scenario. Same membrane principle as a quote: margin / gross / deliberation /
  # unselected scenarios NEVER appear. The financial breakdown is fed exclusively by
  # Engine::Result#customer_h, which structurally omits dealer gross.
  #
  # Branded by the SELLING LOCATION (logo / colors / name / address / phone + salesperson),
  # using the industry/label system for wording (e.g. "Home" vs "Unit"). Prints
  # "valid through [date]" from the scenario's validity window. v1: single selected scenario.
  class SummaryPdfGenerator
    def initialize(scenario)
      @scenario = scenario
      @deal     = scenario.deal
      @company  = scenario.company
      @unit     = scenario.vehicle
      @location = scenario.location || @deal&.location
      @labels   = (@company.resolved_labels rescue {}) || {}
    end

    def generate
      brand = resolve_branding
      @accent = brand[:accent]

      pdf = Prawn::Document.new(page_size: 'LETTER', margin: [44, 50, 70, 50])
      add_header(pdf, brand)
      pdf.move_down 14
      add_unit(pdf)
      pdf.move_down 12
      add_price_breakdown(pdf)
      pdf.move_down 12
      add_payment(pdf)
      add_footer(pdf)
      pdf.render
    end

    private

    def unit_label
      @labels['vehicle'].presence || 'Unit'
    end

    def id_label
      @labels['vin'].presence || 'Serial / VIN'
    end

    def salesperson_name
      (@deal&.primary_salesperson || @deal&.owner || @scenario.created_by)&.name
    end

    # --- Branding (Location → Company waterfall), mirrors QuotePdfGenerator ----
    def resolve_branding
      branding = {}
      if @location.present?
        branding = (Setting.get('Location', @location.id, 'branding') rescue nil) || {}
      end
      branding = (Setting.get('Company', @company.id, 'branding') rescue nil) || {} if branding.blank?

      {
        logo_url: branding['logo'].presence,
        accent: (branding['primaryColor'] || branding['primary_color'] || '#1F4E79').to_s.delete('#'),
        name: @location&.name || @company.name
      }
    end

    def add_header(pdf, brand)
      top = pdf.cursor

      logo_drawn = false
      if brand[:logo_url].present?
        data = load_image(brand[:logo_url])
        if data
          begin
            pdf.image StringIO.new(data), fit: [160, 56], position: :left
            logo_drawn = true
          rescue StandardError => e
            Rails.logger.warn "[DealDesk PDF] logo draw failed: #{e.message}"
          end
        end
      end
      pdf.text brand[:name], size: 17, style: :bold unless logo_drawn

      pdf.bounding_box([pdf.bounds.right - 230, top], width: 230) do
        pdf.text brand[:name], size: 11, style: :bold, align: :right
        if @location
          line1 = [@location.address_line1, @location.address_line2].compact.reject(&:blank?).join(' ')
          city  = [@location.city, @location.state, @location.zip_code].compact.reject(&:blank?).join(', ')
          pdf.text line1, size: 9, align: :right if line1.present?
          pdf.text city,  size: 9, align: :right if city.present?
          pdf.text @location.phone, size: 9, align: :right if @location.phone.present?
          pdf.text @location.email, size: 9, align: :right if @location.email.present?
        end
      end

      pdf.move_down 8
      pdf.stroke_color @accent
      pdf.stroke_horizontal_rule
      pdf.stroke_color '000000'
      pdf.move_down 8

      buyer = @deal&.customer_name.presence ||
              @deal&.account&.name ||
              [@deal&.contact&.first_name, @deal&.contact&.last_name].compact.join(' ')
      pdf.text 'DEAL SUMMARY', size: 15, style: :bold, color: @accent
      pdf.text "Prepared for: #{buyer}", size: 10 if buyer.present?
      pdf.text "Salesperson: #{salesperson_name}", size: 10 if salesperson_name.present?
    end

    def add_unit(pdf)
      return unless @unit

      pdf.text "The #{unit_label}", size: 12, style: :bold
      pdf.move_down 4

      details = []
      details << [unit_label, [@unit.year, @unit.make, @unit.model].compact.join(' ')]
      id_val = @unit.serial_number.presence || @unit.vin.presence || @unit.stock_number.presence || @unit.inventory_id
      details << [id_label, id_val] if id_val.present?
      bb = [("#{@unit.bedrooms} bd" if @unit.bedrooms), ("#{@unit.bathrooms.to_f} ba" if @unit.bathrooms),
            ("#{@unit.square_feet} sqft" if @unit.respond_to?(:square_feet) && @unit.square_feet)].compact.join('   |   ')
      details << ['Specs', bb] if bb.present?

      pdf.table(details, width: pdf.bounds.width * 0.62,
                cell_style: { borders: [], padding: [2, 4], size: 10 }) do |t|
        t.column(0).font_style = :bold
        t.column(0).width = 110
      end
    end

    def add_price_breakdown(pdf)
      r = @scenario.engine_result.customer_h # gross-free projection
      price = @scenario.unit_price_snapshot.to_f
      trade_net = r[:trade_equity].to_f

      rows = [['Price Breakdown', '']]
      rows << ['Selling Price', usd(price)]
      rows << ['Trade Allowance (less payoff)', usd(trade_net)] unless trade_net.zero?
      rows << ['Fees', usd(r[:total_fees])] if r[:total_fees].to_f.positive?
      rows << ['F&I Products', usd(r[:total_fni])] if r[:total_fni].to_f.positive?
      rows << ['Taxes', usd(r[:taxes])] if r[:taxes].to_f.positive?
      rows << ['Cash Down', usd(@scenario.cash_down)] if @scenario.cash_down.to_f.positive?
      rows << ['Rebates', usd(-@scenario.rebates.to_f)] if @scenario.rebates.to_f.positive?
      rows << ['Amount Financed', usd(r[:amount_financed])]

      pdf.table(rows, width: pdf.bounds.width,
                cell_style: { padding: [6, 8], size: 10, border_width: 0.5, border_color: 'DDDDDD' }) do |t|
        t.row(0).font_style = :bold
        t.row(0).text_color = 'FFFFFF'
        t.row(0).background_color = @accent
        t.row(0).columns(1).text = ''
        t.column(1).align = :right
        t.row(-1).font_style = :bold
        t.row(-1).background_color = 'F2F2F2'
      end
    end

    def add_payment(pdf)
      r = @scenario.engine_result.customer_h

      pdf.bounding_box([0, pdf.cursor], width: pdf.bounds.width) do
        pdf.fill_color 'F2F2F2'
        pdf.fill_rectangle [0, pdf.cursor], pdf.bounds.width, 70
        pdf.fill_color '000000'

        pdf.move_down 10
        pdf.indent(16) do
          pdf.text "APR #{format('%.2f', r[:apr].to_f)}%      Term #{r[:term_months]} months",
                   size: 11
          pdf.move_down 2
          pdf.text usd(r[:monthly_payment]) + ' / month', size: 26, style: :bold, color: @accent
        end
        pdf.bounding_box([pdf.bounds.right - 200, pdf.bounds.top - 12], width: 184) do
          pdf.text 'Out-the-Door', size: 9, align: :right
          pdf.text usd(r[:out_the_door]), size: 15, style: :bold, align: :right
        end
      end
      pdf.move_down 16
    end

    def add_footer(pdf)
      pdf.move_cursor_to 96
      pdf.stroke_color 'CCCCCC'
      pdf.stroke_horizontal_rule
      pdf.stroke_color '000000'
      pdf.move_down 8

      if @scenario.valid_through
        pdf.text "Valid through #{@scenario.valid_through.strftime('%B %-d, %Y')}",
                 size: 10, style: :bold
      end
      pdf.move_down 4
      pdf.text 'This is an estimate, not a financing commitment. Figures subject to credit ' \
               'approval, verification, taxes and fees. Not an offer to extend credit.',
               size: 7.5, color: '777777'
      pdf.move_down 14
      pdf.text "Buyer signature: ______________________________    Date: ____________", size: 9
    end

    # --- Image loading (local /uploads or HTTP, mirrors QuotePdfGenerator) ----
    def load_image(url)
      return nil if url.blank?

      if url.include?('/uploads/')
        rel = url.sub(%r{^https?://[^/]+}, '')
        base = ENV['UPLOAD_PATH'] || Rails.root.join('public', 'uploads').to_s
        candidates = [File.join(base.sub(%r{/uploads$}, ''), rel.sub(%r{^/}, '')),
                      File.join(base, rel.sub(%r{^/uploads/}, ''))]
        path = candidates.find { |p| File.exist?(p) }
        return File.binread(path) if path
      end

      return nil unless url.start_with?('http://', 'https://')

      uri = URI.parse(url)
      redirects = 0
      loop do
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == 'https')
        http.open_timeout = 5
        http.read_timeout = 10
        resp = http.request(Net::HTTP::Get.new(uri.request_uri))
        case resp
        when Net::HTTPSuccess then return resp.body
        when Net::HTTPRedirection
          redirects += 1
          return nil if redirects > 3

          uri = URI.parse(resp['location'])
        else return nil
        end
      end
    rescue StandardError => e
      Rails.logger.warn "[DealDesk PDF] image load failed: #{e.message}"
      nil
    end

    def usd(amount)
      ActiveSupport::NumberHelper.number_to_currency(amount.to_f)
    end
  end
end
