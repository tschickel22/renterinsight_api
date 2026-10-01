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

    # copied_from: the token of a shared design this one was saved from (a
    # family member's own copy), so the original's owner hears about it.
    # buyer_access: the buyer is signed in (a Truebuild::BuyerPass from My
    # Designs): the design goes to their lead or contact, with no contact
    # form, intake submission or new portal login.
    def initialize(company:, variant:, vehicle: nil, option_ids: [], contact: {}, request: nil, context: {}, addon_ids: [],
                   copied_from: nil, buyer_access: nil)
      @buyer_access = buyer_access
      @copied_from = copied_from.present? ? company.truebuild_designs.find_by(public_token: copied_from.to_s) : nil
      @company = company
      @variant = variant
      @vehicle = vehicle
      @option_ids = option_ids
      @addon_ids = addon_ids
      @contact = contact.to_h.transform_keys(&:to_s)
      @request = request
      @context = context.to_h.transform_keys(&:to_s)
    end

    def call
      return save_for_signed_in_buyer if @buyer_access

      validate!
      catalog = BuyerCatalog.new(@company, @variant, location: @vehicle&.location)
      price = catalog.price(@option_ids, @addon_ids)

      design = @company.truebuild_designs.create!(
        variant: @variant, vehicle: @vehicle, option_ids: price[:option_ids], price_book: BookResolver.current_for(@variant),
        name: "#{@variant.catalog_plan.name} (#{@variant.model_number})",
        buyer_email: @contact['email'].to_s.strip.downcase,
        buyer_name: [@contact['first_name'], @contact['last_name']].compact.join(' ').strip,
        price_snapshot: snapshot(price).deep_stringify_keys,
        metadata: { 'addon_ids' => price[:addon_ids], 'utm' => @context.slice(*%w[utm_source utm_medium utm_campaign utm_content utm_term]),
                    'page_url' => @context['page_url'].presence, 'copied_from' => @copied_from&.id }.compact.deep_stringify_keys
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
      PortalAccess.call(design)
      design.track!('saved')
      # Someone else's copy: tell the original buyer's dealer too, unless the
      # buyer saved a new version of their own.
      if @copied_from && @copied_from.buyer_email != design.buyer_email
        @copied_from.track!('copied', copy_id: design.id, copied_by: design.buyer_name.presence)
      end
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

    def save_for_signed_in_buyer
      buyer = @buyer_access.buyer
      price = BuyerCatalog.new(@company, @variant, location: @vehicle&.location).price(@option_ids, @addon_ids)
      contact = buyer.is_a?(Contact) ? buyer : nil
      design = @company.truebuild_designs.create!(
        variant: @variant, vehicle: @vehicle, option_ids: price[:option_ids], price_book: BookResolver.current_for(@variant),
        name: "#{@variant.catalog_plan.name} (#{@variant.model_number})",
        buyer_email: @buyer_access.email.to_s.downcase,
        buyer_name: [buyer.try(:first_name), buyer.try(:last_name)].compact.join(' ').strip,
        lead_id: buyer.is_a?(Lead) ? buyer.id : @copied_from&.lead_id, contact_id: contact&.id, account_id: contact&.account_id,
        price_snapshot: snapshot(price).deep_stringify_keys,
        metadata: { 'addon_ids' => price[:addon_ids], 'page_url' => @context['page_url'].presence, 'copied_from' => @copied_from&.id,
                    'saved_signed_in' => true }.compact.deep_stringify_keys
      )
      design.track!('saved')
      if @copied_from && @copied_from.buyer_email != design.buyer_email
        @copied_from.track!('copied', copy_id: design.id, copied_by: design.buyer_name.presence)
      end
      design
    end

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
      message = []
      # Saved from someone else's shared design: say whose, so the rep knows
      # this buyer came through a family member or friend.
      if shared_copy?(design)
        message << "Shared with them by #{@copied_from.buyer_name.presence || 'another buyer'}, from their #{@copied_from.name} " \
                   "design (#{design_url(@copied_from)})."
      end
      message << "Designed a #{design.name} on the website."
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
      }.merge(share_utms(design)).merge(@context.slice(*%w[utm_source utm_medium utm_campaign utm_content utm_term]).compact_blank).compact
    end

    def design_url(design)
      self.class.design_url(design)
    end

    def shared_copy?(design)
      @copied_from.present? && @copied_from.buyer_email != design.buyer_email
    end

    # A shared design's copies report as their own channel. The source stays
    # TrueBuild: it is what starts the dealer's Saved home design play.
    def share_utms(design)
      return {} unless shared_copy?(design)

      { 'utm_source' => 'truebuild', 'utm_medium' => 'share', 'utm_campaign' => 'design_share' }
    end

    # Where the buyer designed it, with the design reopened.
    def self.design_url(design)
      page = design.metadata['page_url'].to_s
      base = page.present? ? page.sub(/[?#].*\z/, '') : Brand.current(company: design.company).app_url.to_s
      "#{base}?design=#{design.public_token}"
    end
  end
end
