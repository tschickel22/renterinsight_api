# frozen_string_literal: true

# The sale details a contract needs beyond the Deal Sheet's price (backlog
# E46), shown as sections 4 (Buyer and site) and 5 (Contract) of the Deal
# Sheet. What the deal already holds is filled in and shown, not retyped:
# the buyers, the delivery address, payment type, lender, the serial number
# of the home received on the factory PO. The rest is stored on the deal in
# sale_details. Every value is also an agreement merge field (sale.<key>).
# The choice lists are Factory Direct's, as the platform's starting lists.
class DealSaleDetails
  CHOICES = {
    'site_ownership' => ['Buyer owns the land', 'Buyer is purchasing the land', 'Leased lot / community', 'Family land, written permission on file'],
    'contingency' => ['No contingency: authorization to build (funds committed)', 'Subject to financing approval',
                      "Subject to sale or closing of Buyer's existing home", "Subject to Buyer's purchase or closing on land",
                      'Subject to zoning, permit or community approval', 'Subject to lender appraisal / valuation',
                      "Subject to Buyer's site being delivery-ready by a date certain", 'Other, described on the agreement'],
    'loan_type' => ['Chattel / home-only', 'Land-home (real property)', 'Construction to permanent', 'FHA Title I', 'FHA Title II', 'VA', 'USDA', 'Other'],
    'land_status' => ['Buyer owns free and clear', 'Buyer owns, mortgaged', 'Buyer purchasing, closing required', 'Leased lot / community',
                      'Family land, written permission required'],
    'payment_method' => ['Wire transfer', "Cashier's check", 'Certified check', 'Personal check, must clear before release', 'ACH transfer',
                         'Currency (cash)', 'Combination, described in notes']
  }.freeze

  # key => type. Dates are YYYY-MM-DD.
  FIELDS = {
    'site_ownership' => :choice, 'county' => :text, 'community_name' => :text, 'lot_number' => :text, 'landlord' => :text,
    'contingency' => :choice, 'contingency_deadline' => :date, 'contingency_description' => :text, 'estimated_completion' => :date,
    'loan_type' => :choice, 'loan_officer' => :text, 'land_status' => :choice, 'approval_date' => :date, 'approval_expires' => :date,
    'payment_method' => :choice, 'deposit_received_on' => :date, 'balance_due_by' => :date,
    'hud_labels' => :text, 'model_year' => :text
  }.freeze

  # Deal columns edited here too: already on the deal, shown in the sections.
  DEAL_FIELDS = %w[payment_type lender_id down_payment_due_date delivery_street delivery_city delivery_state delivery_zip].freeze

  class Invalid < StandardError; end

  def initialize(deal)
    @deal = deal
  end

  def as_json(*)
    { values: values, filled: filled, choices: CHOICES, lenders: lenders, missing: missing }
  end

  def values = FIELDS.keys.index_with { |k| @deal.sale_details.to_h[k] }.merge('county' => county)

  # Saves sale details and the deal columns edited here. Blank clears.
  def update!(params)
    params = params.to_h.stringify_keys
    details = @deal.sale_details.to_h.dup
    (params.keys & FIELDS.keys).each do |key|
      details[key] = clean(key, params[key])
    end
    deal_attrs = params.slice(*DEAL_FIELDS)
    if deal_attrs.key?('lender_id') && deal_attrs['lender_id'].present?
      lender = @deal.company.lenders.find_by(id: deal_attrs['lender_id']) or raise Invalid, 'That lender is not one of yours'
      deal_attrs['lender_name'] = lender.name
    end
    @deal.assign_attributes(deal_attrs.merge('sale_details' => details.compact))
    @deal.save!
    self
  end

  # What a contract cannot go out without (the ready-to-send check).
  def missing
    out = []
    out << 'Buyer' unless @deal.contact
    out << 'Delivery address' if @deal.delivery_street.blank? || @deal.delivery_city.blank?
    out << 'Site ownership' if values['site_ownership'].blank?
    out << 'Contingency' if values['contingency'].blank?
    out << 'Cash or finance' unless finance? || cash?
    if finance?
      out << 'Lender' if @deal.lender_id.blank? && @deal.lender_name.blank?
      out << 'Loan type' if values['loan_type'].blank?
    end
    out << 'Payment method' if cash? && values['payment_method'].blank?
    out
  end

  # payment_type: cash, finance (or financed), or cash_and_finance, which takes both addenda.
  def finance? = @deal.payment_type.to_s.downcase.match?(/financ|loan/)
  def cash? = @deal.payment_type.to_s.downcase.include?('cash')

  private

  def filled
    buyer = ->(c) { c && { name: [c.first_name, c.last_name].compact.join(' ').squish, email: c.email, phone: c.phone,
                           address: [c.street, [c.city, c.state, c.zip].compact.join(' ').squish].reject(&:blank?).join(', ') } }
    received = @deal.purchase_orders.where.not(received_vehicle_id: nil).order(:id).last&.received_vehicle
    { buyer_1: buyer.call(@deal.contact), buyer_2: buyer.call(@deal.co_applicant_contact),
      delivery: { street: @deal.delivery_street, city: @deal.delivery_city, state: @deal.delivery_state, zip: @deal.delivery_zip },
      payment_type: @deal.payment_type, lender_id: @deal.lender_id, lender_name: @deal.lender_name,
      down_payment_due_date: @deal.down_payment_due_date&.iso8601, expected_delivery: @deal.delivery_date&.iso8601,
      serial_number: received&.serial_number.presence || @deal.vehicle&.serial_number.presence }
  end

  # Typed, or the home's county when it has one on record.
  def county = @deal.sale_details.to_h['county'].presence || @deal.vehicle&.try(:county_name).presence

  def lenders = @deal.company.respond_to?(:lenders) ? @deal.company.lenders.order(:name).map { |l| { id: l.id, name: l.name } } : []

  def clean(key, value)
    value = value.to_s.strip
    return nil if value.empty?

    case FIELDS[key]
    when :choice
      raise Invalid, "#{value} is not one of the #{key.humanize.downcase} choices" unless CHOICES[key].include?(value)
    when :date
      begin
        value = Date.iso8601(value).iso8601
      rescue ArgumentError
        raise Invalid, "#{key.humanize} needs a date"
      end
    end
    value.truncate(500)
  end
end
