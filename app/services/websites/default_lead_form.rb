# frozen_string_literal: true

module Websites
  # The intake form a generated site's contact block should submit to.
  #
  # projectProfile has accepted a leadFormId since it was written, and
  # SiteRenderer's contact block requires one, but nothing in production ever
  # passed it. So every demo and every committed site rendered "Contact form not
  # available" where the contact form should be, and the calculator's quote
  # button — which needs the same id — never appeared at all.
  #
  # The form MUST belong to the same company as the inventory embed token. The
  # public endpoint authenticates with that token and scopes the lookup to that
  # company (Api::Crm::Intake::FormsController#set_form), so a form borrowed
  # from anywhere else 404s. That is why this resolves from the lot company
  # rather than the profile's tenant.
  #
  # Preference order matters for a demo: a campaign form named "New Home Sales
  # Special — Lowest Prices in East Texas" is a real form, but showing it as the
  # contact form on a prospect's preview reads as someone else's marketing.
  class DefaultLeadForm
    # A form meant for "get in touch", rather than one built for a campaign.
    GENERAL_PURPOSE = /contact|get in touch|inquir|request info|more info|general/i

    # Campaign and channel forms. Real, but wrong for a contact block.
    CAMPAIGN_SPECIFIC = /facebook|google|instagram|tiktok|special|promo|sale|event|test/i

    # The form created when a company has nothing suitable. leadField values are
    # the ones already in use across real forms, so a submission maps onto a
    # Lead exactly as every other form's does.
    BASIC_FIELDS = [
      { name: 'First Name', label: 'First Name', type: 'text',     required: true,  lead_field: 'first_name' },
      { name: 'Last Name',  label: 'Last Name',  type: 'text',     required: true,  lead_field: 'last_name' },
      { name: 'Email',      label: 'Email',      type: 'email',    required: true,  lead_field: 'email' },
      { name: 'Phone',      label: 'Phone',      type: 'tel',      required: false, lead_field: 'phone' },
      { name: 'Message',    label: 'How can we help?', type: 'textarea', required: false, lead_field: 'notes' }
    ].freeze

    def self.for(company)
      new(company).call
    end

    # Find, or build a basic contact form.
    #
    # Only ever called from paths that are already writing — a scan finishing, a
    # website being created. Never from a render: a GET that creates records is
    # a surprise, and one that does it per page view is a bug waiting to
    # happen.
    #
    # Idempotent by construction, since a company that has a usable form gets
    # it back instead of a second one.
    def self.ensure_for(company)
      return nil if company.nil?

      existing = new(company).call
      return existing if existing && GENERAL_PURPOSE.match?(existing.name.to_s)

      create_basic(company)
    rescue StandardError => e
      # A site is still worth having without a form; the resolver will simply
      # keep returning whatever else exists.
      Rails.logger.warn("[Websites::DefaultLeadForm] could not create a form for #{company&.id}: #{e.message}")
      existing
    end

    def self.create_basic(company)
      schema = BASIC_FIELDS.each_with_index.map do |f, i|
        {
          'id' => SecureRandom.uuid, 'name' => f[:name], 'label' => f[:label],
          'type' => f[:type].to_s, 'required' => f[:required], 'placeholder' => '',
          'order' => i + 1, 'isActive' => true, 'leadField' => f[:lead_field]
        }
      end

      company.intake_forms.create!(
        name: 'Contact Us',
        description: 'General enquiries from the website.',
        schema: schema,
        is_active: true,
        auto_create_lead: true,
        auto_create_activity: true,
        submit_button_text: 'Send Message',
        thank_you_message: 'Thanks for reaching out. We will get back to you shortly.',
        field_mappings: schema.to_h { |f| [f['name'], f['leadField']] }
      )
    end

    def initialize(company)
      @company = company
    end

    # @return [IntakeForm, nil]
    def call
      return nil if @company.nil?

      forms = active_forms
      return nil if forms.empty?

      forms.find { |f| GENERAL_PURPOSE.match?(f.name.to_s) } ||
        forms.find { |f| !CAMPAIGN_SPECIFIC.match?(f.name.to_s) } ||
        forms.first
    end

    private

    # Oldest first: a company's original form is the general one far more often
    # than its newest, which is usually whatever campaign shipped last.
    #
    # A form with no schema renders as an empty box, which looks more broken
    # than no form at all, so those are skipped.
    def active_forms
      @company.intake_forms.active.order(:created_at).to_a.select { |f| f.schema.present? }
    rescue StandardError => e
      Rails.logger.warn("[Websites::DefaultLeadForm] lookup failed for #{@company&.id}: #{e.message}")
      []
    end
  end
end
