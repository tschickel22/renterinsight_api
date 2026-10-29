# frozen_string_literal: true

require 'combine_pdf'
require 'bigdecimal'

# Generates check PDFs for a batch of PrintedCheck records.
#
# Two modes (driven by bank_account.check_format):
#   - "pre_printed" (default): only variable data is drawn (date, payee, amount,
#     amount-in-words, memo, vendor address, optional digital signature) plus
#     two stub copies below the check.
#   - "blank": draws the full check chrome (company header, bank header, "PAY
#     TO THE ORDER OF" labels, MICR line, signature heading) in addition to
#     the variable data.
#
# Coordinates are tuned for standard US Letter check stock with the check at
# the top of the page (positions ported from the Renter Insight legacy app).
class CheckPrintingService
  include ActionView::Helpers::NumberHelper

  Y_ADJUSTMENT = -3
  MICR_FONT_PDF = Rails.root.join('public', 'pdfs', 'micr-e13b.pdf').freeze

  ONES = %w[Zero One Two Three Four Five Six Seven Eight Nine Ten Eleven Twelve
            Thirteen Fourteen Fifteen Sixteen Seventeen Eighteen Nineteen].freeze
  TENS = %w[Zero Ten Twenty Thirty Forty Fifty Sixty Seventy Eighty Ninety].freeze
  SCALES = ['', 'Thousand', 'Million', 'Billion', 'Trillion'].freeze

  def self.generate_checks(printed_checks)
    new.generate(printed_checks)
  end

  def self.generate_pdf_bytes(printed_checks)
    generate_checks(printed_checks).to_pdf
  end

  def generate(printed_checks)
    pdf = CombinePDF.new
    register_fonts

    Array(printed_checks).each_with_index do |check, idx|
      pdf.new_page
      page = pdf.pages[idx]
      bank_account = check.bank_account

      render_blank_check_chrome(page, check, bank_account) if bank_account&.check_format.to_s == 'blank'
      render_variable_data(page, check, bank_account)
      render_stubs(page, check)
    end

    pdf
  end

  private

  def register_fonts
    @custom_fonts_available = false
    return unless File.exist?(MICR_FONT_PDF)

    fonts = CombinePDF.new(MICR_FONT_PDF.to_s).fonts(true)
    if fonts && fonts[0] && fonts[1]
      CombinePDF.register_font_from_pdf_object(:autography, fonts[0])
      CombinePDF.register_font_from_pdf_object(:micr_e13b, fonts[1])
      @custom_fonts_available = true
    end
  rescue StandardError => e
    Rails.logger.warn("CheckPrintingService: MICR font registration failed — #{e.message}")
  end

  def text_props
    { font_size: 11, text_align: :left, height: 20, width: 300 }
  end

  def render_blank_check_chrome(page, check, ba)
    company = check.company
    company_name   = ba.check_company_name.presence   || company&.try(:name)
    company_street = ba.check_company_street.presence || company&.try(:street)
    company_phone  = ba.check_company_phone.presence  || company&.try(:phone) || company&.try(:cell_phone)
    company_city_line =
      if ba.check_company_city.present?
        "#{ba.check_company_city}, #{ba.check_company_state} #{ba.check_company_zip}".strip
      else
        city = company&.try(:city)
        state_zip = [company&.try(:state), company&.try(:zip)].compact.join(' ').strip
        [city, state_zip].reject(&:blank?).join(', ')
      end

    # Company header (top-left of check)
    page.textbox company_name.to_s, text_props.merge(y: Y_ADJUSTMENT + 752, x: 10, text_align: :center, font_size: 12) if company_name.present?
    page.textbox company_street.to_s, text_props.merge(y: Y_ADJUSTMENT + 738, x: 10, text_align: :center, font_size: 10) if company_street.present?
    page.textbox company_city_line.to_s, text_props.merge(y: Y_ADJUSTMENT + 728, x: 10, text_align: :center, font_size: 10) if company_city_line.present?
    page.textbox "PH: #{company_phone}", text_props.merge(y: Y_ADJUSTMENT + 716, x: 10, text_align: :center, font_size: 10) if company_phone.present?

    # Bank info (top-center)
    page.textbox ba.check_bank_name.to_s, text_props.merge(y: Y_ADJUSTMENT + 756, x: 220, font_size: 7, text_align: :center) if ba.check_bank_name.present?
    if ba.check_bank_city.present? || ba.check_bank_state.present?
      page.textbox "#{ba.check_bank_city}, #{ba.check_bank_state}".strip, text_props.merge(y: Y_ADJUSTMENT + 748, x: 220, font_size: 7, text_align: :center)
    end
    page.textbox ba.check_aba_fractional_number.to_s, text_props.merge(y: Y_ADJUSTMENT + 740, x: 220, font_size: 7, text_align: :center) if ba.check_aba_fractional_number.present?

    # Check number (top-right)
    check_no = check.check_number.to_s.rjust(8, '0')
    page.textbox check_no, text_props.merge(y: Y_ADJUSTMENT + 750, x: 310, font_size: 18, text_align: :right)

    # Date line
    page.textbox '________________', text_props.merge(y: Y_ADJUSTMENT + 712, x: 390, text_align: :center)

    # PAY TO THE ORDER OF labels
    page.textbox 'PAY TO THE', text_props.merge(y: Y_ADJUSTMENT + 686, x: -10, font_size: 9)
    page.textbox 'ORDER OF  ________________________________________________________________________________',
                 text_props.merge(y: Y_ADJUSTMENT + 678, x: -10, font_size: 9)

    # Amount box and DOLLARS line
    page.textbox '$______________', text_props.merge(y: Y_ADJUSTMENT + 680, x: 445, font_size: 14)
    page.textbox '_____________________________________________________________________________________ DOLLARS',
                 text_props.merge(y: Y_ADJUSTMENT + 658, x: -10)

    # Signature heading
    if ba.check_signature_heading.present?
      page.textbox ba.check_signature_heading.to_s, text_props.merge(y: Y_ADJUSTMENT + 645, x: 330, font_size: 7, text_align: :center)
    end
    page.textbox company_name.to_s, text_props.merge(y: Y_ADJUSTMENT + 638, x: 330, font_size: 7, text_align: :center) if company_name.present?

    # Memo + signature lines
    page.textbox 'MEMO ____________________________________', text_props.merge(y: Y_ADJUSTMENT + 586, x: -10)
    page.textbox '_______________________________', text_props.merge(y: Y_ADJUSTMENT + 586, x: 330, text_align: :center)
    page.textbox 'AUTHORIZED SIGNATURE', text_props.merge(y: Y_ADJUSTMENT + 580, x: 330, text_align: :center, font_size: 7)

    # MICR line — only when the MICR font has been registered
    if @custom_fonts_available
      page.textbox "C#{check.check_number.to_s.rjust(10, '0')}C",
                   text_props.merge(y: Y_ADJUSTMENT + 552, x: 44, font: :micr_e13b, font_size: 12)
      page.textbox "A#{ba.routing_number}A#{ba.account_number}C",
                   text_props.merge(y: Y_ADJUSTMENT + 554, x: 175, font: :micr_e13b, font_size: 12)
    end
    # TODO: upload public/pdfs/micr-e13b.pdf to enable MICR encoding when missing.

    # Two stub headers below the check
    [528, 276].each do |stub_y|
      page.textbox '-' * 175, text_props.merge(y: Y_ADJUSTMENT + stub_y, x: -40)
      page.textbox company_name.to_s, text_props.merge(y: Y_ADJUSTMENT + stub_y - 4, x: -10, font_size: 10) if company_name.present?
      page.textbox company_street.to_s, text_props.merge(y: Y_ADJUSTMENT + stub_y - 14, x: -10, font_size: 10) if company_street.present?
      page.textbox check_no, text_props.merge(y: Y_ADJUSTMENT + stub_y - 18, x: 310, font_size: 18, text_align: :right)
    end
  end

  def render_variable_data(page, check, ba)
    date_str = (check.printed_on || Date.current).strftime('%m/%d/%Y')
    page.textbox date_str, text_props.merge(y: Y_ADJUSTMENT + 718, x: 480)
    page.textbox check.paid_to.to_s, text_props.merge(y: Y_ADJUSTMENT + 684, x: 50)
    page.textbox number_to_currency(check.amount, unit: ''), text_props.merge(y: Y_ADJUSTMENT + 684, x: 480)

    words_line = "#{amount_to_words(check.amount)}  ".ljust(115, '-')
    page.textbox words_line, text_props.merge(y: Y_ADJUSTMENT + 658, x: -10)

    render_vendor_address(page, check)

    page.textbox check.memo.to_s, text_props.merge(y: Y_ADJUSTMENT + 590, x: 28) if check.memo.present?

    if ba && ba.check_signor_name.present?
      sig_props = text_props.merge(y: Y_ADJUSTMENT + 594, x: 330, text_align: :center, font_size: 18)
      sig_props = sig_props.merge(font: :autography) if @custom_fonts_available
      page.textbox ba.check_signor_name, sig_props
    end
  end

  def render_vendor_address(page, check)
    target = check.try(:vendor) || check.contact
    return if target.blank?

    name = target.try(:company_name).presence ||
           [target.try(:first_name), target.try(:last_name)].compact.reject(&:blank?).join(' ').presence ||
           target.try(:name)
    return if name.blank?

    page.textbox name.to_s, text_props.merge(y: Y_ADJUSTMENT + 630, x: 50)
    page.textbox target.try(:street).to_s, text_props.merge(y: Y_ADJUSTMENT + 619, x: 50) if target.try(:street).present?

    city = target.try(:city)
    if city.present?
      city_line = "#{city}, #{target.try(:state)} #{target.try(:zip)}".strip
      page.textbox city_line, text_props.merge(y: Y_ADJUSTMENT + 610, x: 50)
    end
  end

  def render_stubs(page, check)
    date_str = (check.printed_on || Date.current).strftime('%m/%d/%Y')
    [1, 2].each do |stub_number|
      base_y = Y_ADJUSTMENT + 682 - stub_number * 240
      page.textbox check.paid_to.to_s, text_props.merge(y: base_y, x: -10)
      page.textbox date_str, text_props.merge(y: base_y, x: 310, text_align: :right)
      page.textbox check.memo.to_s, text_props.merge(y: base_y - 17, x: -10) if check.memo.present?
      page.textbox check.description.to_s, text_props.merge(y: base_y - 17, x: 200) if check.description.present?
      page.textbox number_to_currency(check.amount), text_props.merge(y: base_y - 17, x: 310, text_align: :right)
    end
  end

  def amount_to_words(amount)
    decimal = amount.is_a?(BigDecimal) ? amount : BigDecimal(amount.to_s)
    dollars = decimal.to_i
    cents = ((decimal - dollars) * 100).round.to_i
    "#{integer_to_words(dollars).strip} & #{cents.to_s.rjust(2, '0')}/100"
  end

  def integer_to_words(num)
    return 'Zero' if num.zero?

    parts = []
    scale_idx = 0
    n = num.abs
    while n.positive?
      group = n % 1000
      if group.positive?
        chunk = three_digit_to_words(group)
        chunk = "#{chunk} #{SCALES[scale_idx]}" if scale_idx.positive?
        parts.unshift(chunk)
      end
      n /= 1000
      scale_idx += 1
    end

    result = parts.join(' ')
    num.negative? ? "Negative #{result}" : result
  end

  def three_digit_to_words(num)
    parts = []
    if num >= 100
      parts << "#{ONES[num / 100]} Hundred"
      num %= 100
    end
    if num >= 20
      tens_word = TENS[num / 10]
      one = num % 10
      parts << (one.zero? ? tens_word : "#{tens_word}-#{ONES[one]}")
    elsif num.positive?
      parts << ONES[num]
    end
    parts.join(' ')
  end
end
