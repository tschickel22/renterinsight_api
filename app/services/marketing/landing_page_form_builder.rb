# frozen_string_literal: true

module Marketing
  # Creates the IntakeForm a landing page collects leads through.
  #
  # An IntakeForm is a database record, so it cannot come from the frontend
  # projection the way blocks do. It is built here from the field list the AI
  # produced (or a sensible default), bound to the page's location and source,
  # and handed back so the contact block can reference it.
  #
  # Reuses the existing intake pipeline rather than inventing a parallel one:
  # submissions run through IdentityResolver, absorb into existing leads, notify
  # the assigned rep, and — since Phase 3 — retro-attribute the visitor's whole
  # session. None of that would exist on a bespoke landing page form.
  class LandingPageFormBuilder
    # What to ask when the model gave nothing usable. Deliberately short: every
    # field costs conversions, and this is what a salesperson needs to make the
    # first call.
    DEFAULT_FIELDS = [
      { 'name' => 'first_name', 'label' => 'First Name', 'type' => 'text',  'required' => true },
      { 'name' => 'last_name',  'label' => 'Last Name',  'type' => 'text',  'required' => false },
      { 'name' => 'email',      'label' => 'Email',      'type' => 'email', 'required' => true },
      { 'name' => 'phone',      'label' => 'Phone',      'type' => 'tel',   'required' => false }
    ].freeze

    def initialize(company:, title:, fields: nil, location: nil, notified_user: nil, source: nil)
      @company = company
      @title = title
      @fields = fields
      @location = location
      @notified_user = notified_user
      @source = source
    end

    def call
      IntakeForm.create!(
        company_id: @company.id,
        name: "#{@title} — Landing Page",
        schema: normalized_fields,
        is_active: true,
        location_id: @location&.id,
        notified_user_id: @notified_user&.id,
        source_id: @source&.id,
        auto_create_lead: true,
        auto_create_activity: true,
        submit_button_text: 'Send',
        thank_you_message: 'Thanks — we will be in touch shortly.'
      )
    end

    private

    # The AI's field list is advisory. Anything unusable is replaced wholesale
    # rather than partially repaired: a form missing the field that carries the
    # lead's contact details captures nothing, and a half-valid form is harder
    # to notice than an obviously default one.
    def normalized_fields
      fields = Array(@fields).select { |f| f.is_a?(Hash) && f['name'].present? }
      return DEFAULT_FIELDS.map(&:dup) if fields.empty?
      return DEFAULT_FIELDS.map(&:dup) unless fields.any? { |f| %w[email tel].include?(f['type'].to_s) }

      fields.map { |f| f.slice('name', 'label', 'type', 'required', 'options') }
    end
  end
end
