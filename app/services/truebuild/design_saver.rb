# frozen_string_literal: true

module Truebuild
  # Saves a buyer's design and hands the buyer to the dealer as a lead.
  #
  # The lead goes through the dealer's intake form like any website lead, so
  # round-robin, duplicate matching, the "Saved home design" play and
  # notifications all apply. The form is the one that play created (source
  # TrueBuild); a dealer who has not turned the play on gets one made here.
  class DesignSaver
    SOURCE = 'TrueBuild'
    FORM_NAME = 'TrueBuild saved design'

    class Invalid < StandardError; end

    def initialize(company:, variant:, vehicle: nil, option_ids: [], contact: {}, request: nil, context: {})
      @company = company
      @variant = variant
      @vehicle = vehicle
      @option_ids = option_ids
      @contact = contact.to_h.transform_keys(&:to_s)
      @request = request
      @context = context.to_h.transform_keys(&:to_s)
    end

    def call
      validate!
      catalog = BuyerCatalog.new(@company, @variant, location: @vehicle&.location)
      price = catalog.price(@option_ids)

      design = @company.truebuild_designs.create!(
        variant: @variant, vehicle: @vehicle, option_ids: price[:option_ids], price_book: BookResolver.current_for(@variant),
        name: "#{@variant.catalog_plan.name} (#{@variant.model_number})",
        buyer_email: @contact['email'].to_s.strip.downcase,
        buyer_name: [@contact['first_name'], @contact['last_name']].compact.join(' ').strip,
        price_snapshot: snapshot(price).deep_stringify_keys,
        metadata: { 'utm' => @context.slice(*%w[utm_source utm_medium utm_campaign utm_content utm_term]) }.deep_stringify_keys
      )

      form = self.class.form_for(@company)
      # As on every intake form: absence is refusal, and the wording is copied as shown.
      consented = form.marketing_consent? && ActiveModel::Type::Boolean.new.cast(@contact['marketing_consent']) == true
      submission = form.intake_submissions.create!(
        data: submission_data(design, price, form),
        ip_address: @request&.remote_ip, user_agent: @request&.user_agent, referrer: @request&.referer,
        submitted_at: Time.current, marketing_consent: consented,
        marketing_consent_text: (form.resolved_marketing_consent_text if consented),
        marketing_consent_at: (Time.current if consented)
      )
      design.update!(intake_submission: submission, lead_id: submission.reload.lead_id)
      design
    end

    # The dealer's TrueBuild intake form: the play's, or one made now.
    def self.form_for(company)
      source = company.sources.find_or_create_by!(name: SOURCE) { |s| s.is_active = true }
      company.intake_forms.where(source_id: source.id, is_active: true).order(:created_at).first ||
        create_form(company, source)
    end

    def self.create_form(company, source)
      fields = Plays::LeadResponsePlay::CONTACT_FIELDS + [Plays::LeadResponsePlay::MESSAGE_FIELD]
      schema = fields.each_with_index.map do |f, i|
        { 'id' => SecureRandom.uuid, 'name' => f[:name], 'label' => f[:label], 'type' => f[:type],
          'required' => f[:required], 'order' => i + 1, 'isActive' => true, 'leadField' => f[:lead_field] }
      end
      company.intake_forms.create!(
        name: FORM_NAME, description: 'Buyers who save a home they designed on your website.',
        schema: schema, field_mappings: schema.to_h { |f| [f['name'], f['leadField']] }, source_id: source.id,
        is_active: true, auto_create_lead: true, auto_create_activity: true, submit_button_text: 'Save my design',
        thank_you_message: "Thanks. Someone from #{company.name} will be in touch about your home."
      )
    end

    private

    def validate!
      email = @contact['email'].to_s.strip
      raise Invalid, 'An email address is required' unless email.match?(URI::MailTo::EMAIL_REGEXP)
      raise Invalid, 'Your first name is required' if @contact['first_name'].to_s.strip.empty?
    end

    def snapshot(price)
      { 'show_prices' => price[:show_prices], 'total' => price[:total], 'lines' => price[:lines],
        'book_id' => price[:book_id], 'priced_at' => Time.current.iso8601 }
    end

    # source_id is explicit so the lead is a TrueBuild lead (and the Saved
    # home design play starts) even when the buyer arrived from an ad: intake
    # otherwise names the source after utm_source. The UTMs still reach the lead.
    def submission_data(design, price, form)
      options = CatalogOption.where(id: design.option_ids).pluck(:name)
      message = ["Designed a #{design.name} on the website."]
      message << "Options: #{options.join(', ')}." if options.any?
      message << "Price shown: #{ActiveSupport::NumberHelper.number_to_currency(price[:total], precision: 0)}." if price[:show_prices]
      message << @contact['message'].to_s.strip if @contact['message'].present?
      message << "Design link: #{design_url(design)}"

      {
        'First Name' => @contact['first_name'].to_s.strip, 'Last Name' => @contact['last_name'].to_s.strip,
        'Email' => design.buyer_email, 'Phone' => @contact['phone'].to_s.strip, 'Message' => message.join("\n"),
        'truebuild_design_token' => design.public_token,
        'vehicle_id' => @vehicle&.id, 'vehicle_location_id' => @vehicle&.location_id,
        'source' => 'truebuild_design', 'source_id' => form.source_id
      }.merge(@context.slice(*%w[utm_source utm_medium utm_campaign utm_content utm_term])).compact
    end

    # Where the buyer designed it, with the design reopened.
    def design_url(design)
      page = @context['page_url'].to_s
      base = page.present? ? page.sub(/[?#].*\z/, '') : Brand.current(company: @company).app_url.to_s
      "#{base}?design=#{design.public_token}"
    end
  end
end
