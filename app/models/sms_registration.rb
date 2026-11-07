# frozen_string_literal: true

# A dealer's own texting registration (E96 phase 4). One per company.
#
# The dealer fills it in (Settings, Communications, Set up your texting
# number) and submits it; nothing goes to the carriers until a platform admin
# sends it (SmsRegistration::Submitter), because every registration has a
# vetting fee and a monthly campaign fee. SmsRegistration::StatusPoller then
# follows the brand and campaign until approved, buys the number and makes it
# the company's TwilioAccount.
class SmsRegistration < ApplicationRecord
  STATUSES = %w[draft submitted in_review approved live rejected].freeze
  BRAND_TYPES = %w[low_volume_standard standard sole_proprietor].freeze
  BUSINESS_TYPES = ['Limited Liability Corporation', 'Corporation', 'Partnership', 'Sole Proprietorship', 'Non-profit Corporation'].freeze
  CONSENT_SOURCES = %w[website_forms truebuild facebook_lead_ads in_person phone].freeze
  BUSINESS_FIELDS = %w[legal_name dba business_type ein industry street city state zip website].freeze
  CONTACT_FIELDS = %w[first_name last_name title email phone].freeze

  belongs_to :company
  belongs_to :submitted_by_user, class_name: 'User', optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :brand_type, inclusion: { in: BRAND_TYPES }

  before_save :clean_json

  # A draft filled from what we already know about the company.
  def self.prefilled_for(company)
    registration = find_or_initialize_by(company_id: company.id)
    return registration if registration.persisted?

    registration.business = {
      'legal_name' => company.name, 'dba' => company.name, 'industry' => 'REAL_ESTATE',
      'street' => company.try(:address_line1), 'city' => company.try(:city), 'state' => company.try(:state),
      'zip' => company.try(:zip_code),
      'website' => (Assistant::Media.published_site_url(company) rescue nil)
    }.compact
    admin = company.users.active.detect(&:effective_admin?) rescue nil
    registration.contact = { 'first_name' => admin&.first_name, 'last_name' => admin&.last_name, 'email' => admin&.email,
                             'phone' => admin&.try(:phone) }.compact
    registration.consent = { 'sources' => %w[website_forms] }
    registration
  end

  def sole_proprietor?
    brand_type == 'sole_proprietor'
  end

  def editable?
    %w[draft rejected].include?(status)
  end

  def dealer_name
    business['dba'].presence || business['legal_name'].presence || company.name
  end

  def campaign_content
    SmsRegistration::CampaignContent.new(kind: 'dealer', dealer_name: dealer_name, legal_name: business['legal_name'])
  end

  # What a carrier would reject, in words a dealer can act on. Empty means
  # ready to submit.
  def problems
    list = []
    b = business
    c = contact
    list << 'Legal business name' if b['legal_name'].blank?
    unless sole_proprietor?
      list << 'Business type' unless BUSINESS_TYPES.include?(b['business_type'])
      list << 'EIN (9 digits, as on your IRS letter)' unless b['ein'].to_s.gsub(/\D/, '').length == 9
    end
    list << 'Street address' if b['street'].blank?
    list << 'City' if b['city'].blank?
    list << 'State (2 letters)' unless b['state'].to_s.strip.match?(/\A[A-Za-z]{2}\z/)
    list << 'ZIP code' unless b['zip'].to_s.strip.match?(/\A\d{5}(-\d{4})?\z/)
    list << 'Website (starting with https://)' unless b['website'].to_s.start_with?('https://')
    list << "Contact's first and last name" if c['first_name'].blank? || c['last_name'].blank?
    list << "Contact's title" if c['title'].blank? && !sole_proprietor?
    list << "Contact's email" unless c['email'].to_s.match?(/\A[^@\s]+@[^@\s]+\.[a-z]{2,}\z/i)
    list << "Contact's mobile number" unless c['phone'].to_s.gsub(/\D/, '').length.between?(10, 11)
    list << 'Where buyers agree to texts' if Array(consent['sources']).empty?
    list << 'Area code (3 digits)' if preferred_area_code.present? && !preferred_area_code.match?(/\A\d{3}\z/)
    list + campaign_content.problems.map { |p| "Campaign wording: #{p}" }
  end

  # Where the dealer is, in four steps, for the status tracker.
  def stages
    [
      { key: 'submitted', label: 'Submitted', done: submitted_at.present? },
      { key: 'business', label: 'Business verified', done: brand_status == 'APPROVED' },
      { key: 'texting', label: 'Texting approved', done: campaign_status == 'VERIFIED' },
      { key: 'number', label: 'Number live', done: live_at.present? }
    ]
  end

  def log!(event, detail = nil)
    self.events = Array(events) + [{ 'at' => Time.current.iso8601, 'event' => event, 'detail' => detail }.compact]
    save!
  end

  private

  def clean_json
    self.business = business.to_h.stringify_keys.slice(*BUSINESS_FIELDS).transform_values { |v| v.to_s.strip }.compact_blank
    self.contact = contact.to_h.stringify_keys.slice(*CONTACT_FIELDS).transform_values { |v| v.to_s.strip }.compact_blank
    sources = Array(consent.to_h.stringify_keys['sources']).map(&:to_s) & CONSENT_SOURCES
    self.consent = consent.to_h.stringify_keys.slice('notes').merge('sources' => sources)
    business['state'] = business['state'].upcase if business['state']
    business['ein'] = business['ein'].gsub(/\D/, '') if business['ein']
  end
end
