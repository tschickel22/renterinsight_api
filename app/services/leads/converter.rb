# frozen_string_literal: true

module Leads
  # Converting a lead: its account (joined or created), its contact and
  # co-applicant, an optional deal, its activities, tags, notes, open
  # follow-ups, custom fields, marketing consent, TrueBuild designs and
  # followers, then the lead marked converted. Moved here from
  # Api::Crm::LeadsController#convert so the QuickBooks switch converts a lead
  # the same way (Accounting::QboMigration::Poster).
  #
  # Run it inside a transaction; it raises on a failure that must undo the rest.
  class Converter
    Result = Struct.new(:account, :contact, :co_applicant, :deal, :deal_error, :custom_field_gaps, keyword_init: true)

    def initialize(lead, company:, user:)
      @lead = lead
      @company = company
      @user = user
    end

    ACCOUNT_MODES = %w[existing new].freeze

    # Open accounts in the company whose name matches, ignoring case and
    # surrounding spaces. Account names are not unique (two families can both
    # be "Smith"), so this can return more than one.
    def self.accounts_named(company, name)
      key = name.to_s.strip.downcase
      return Account.none if key.blank?

      company.accounts.where(is_deleted: [false, nil]).where('LOWER(TRIM(accounts.name)) = ?', key).order(:id)
    end

    # The name the account gets: the explicit one, else the lead's company
    # name, else the person's name.
    def account_name_for(account_name = nil)
      name = account_name.to_s.strip.presence ||
             @lead.try(:company_name).to_s.strip.presence ||
             "#{@lead.first_name} #{@lead.last_name}".strip
      name.presence || "Converted Lead #{@lead.id}"
    end

    # account_name: the account's name (default: account_name_for).
    # account_mode: 'existing' joins an account with that name (account_id
    #   picks which one when several share it), 'new' always makes a separate
    #   account even when the name is in use. nil joins a same-name account if
    #   there is one, else makes one (the QuickBooks switch relies on this).
    # account_id: with 'existing' (or nil), the account to join. It must be an
    #   open account in this company.
    # create_contact_param: true or false; nil means "when the lead has a first
    #   and last name".
    # deal_params: { name, stage, close_date or expected_close, description }
    #   to open a deal as well.
    def call(account_name: nil, account_mode: nil, account_id: nil, create_contact_param: nil, deal_params: nil)
      raise ArgumentError, 'Lead has already been converted' if @lead.is_converted

      account_mode = account_mode.to_s.presence
      raise ArgumentError, "Unknown account_mode #{account_mode}" if account_mode && !ACCOUNT_MODES.include?(account_mode)

          # Inherit location from lead, fall back to current location selector
          location_id = @lead.location_id || Current.location_id
          # The rep working the lead keeps continuity into the converted records.
          # Falls back to the converter so manager-driven or unowned-lead conversions
          # still produce assigned records.
          inherited_owner_id = @lead.owner_id || @user&.id

          # 1. FIND OR CREATE ACCOUNT
          # Priority: explicit param > lead.company_name > person name fallback.
          account_name = account_name_for(account_name)

          Rails.logger.info "✅ [ConvertLead] Account #{account_name} (mode #{account_mode || 'default'})"

          account =
            if account_mode != 'new' && account_id.present?
              @company.accounts.where(is_deleted: [false, nil]).find(account_id)
            elsif account_mode != 'new'
              self.class.accounts_named(@company, account_name).first
            end

          account ||= Account.create!(name: account_name, company_id: @lead.company_id) do |a|
            a.status = 'active'
            a.email = @lead.email
            a.phone = @lead.phone
            a.source_id = @lead.source_id
            a.notes = @lead.notes
            a.location_id = location_id
            a.owner_id = inherited_owner_id
            a.account_type = 'converted_lead' if a.respond_to?(:account_type=)
            # Copy lead address → account billing address
            a.billing_street      = @lead.street
            a.billing_city        = @lead.city
            a.billing_state       = @lead.state
            a.billing_postal_code = @lead.zip
            a.billing_country     = @lead.country
            # Deposit follows the customer forward
            a.deposit_amount      = @lead.deposit_amount if a.respond_to?(:deposit_amount=)
          end

          Rails.logger.info "✅ [ConvertLead] Account #{account.previously_new_record? ? 'created' : 'reused'}: #{account.id}"

          # 1b. BACKFILL EXISTING ACCOUNT
          # The create block only sets email/phone/address on CREATE. When we
          # join a pre-existing account (e.g. an imported one), fill in any
          # contact fields it's missing from the lead — without overwriting data
          # the account already has.
          unless account.previously_new_record?
            backfill = {}
            backfill[:email]               = @lead.email   if account.email.blank?               && @lead.email.present?
            backfill[:phone]               = @lead.phone   if account.phone.blank?               && @lead.phone.present?
            backfill[:billing_street]      = @lead.street  if account.billing_street.blank?      && @lead.street.present?
            backfill[:billing_city]        = @lead.city    if account.billing_city.blank?        && @lead.city.present?
            backfill[:billing_state]       = @lead.state   if account.billing_state.blank?       && @lead.state.present?
            backfill[:billing_postal_code] = @lead.zip     if account.billing_postal_code.blank? && @lead.zip.present?
            backfill[:billing_country]     = @lead.country if account.billing_country.blank?     && @lead.country.present?
            # Only fill the owner when the existing account is unassigned — never steal
            # ownership from a rep who already owns the account.
            backfill[:owner_id]            = inherited_owner_id if account.owner_id.blank? && inherited_owner_id.present?
            if backfill.any?
              account.update!(backfill)
              Rails.logger.info "✅ [ConvertLead] Backfilled existing account #{account.id}: #{backfill.keys.join(', ')}"
            end
          end

          # 2. CREATE CONTACT (if requested or if we have name data)
          contact = nil
          create_contact = create_contact_param.present? ? 
            ActiveModel::Type::Boolean.new.cast(create_contact_param) : 
            (@lead.first_name.present? && @lead.last_name.present?)

          if create_contact
            Rails.logger.info "✅ [ConvertLead] Creating contact"

            contact_attrs = {
              first_name: @lead.first_name,
              last_name: @lead.last_name,
              email: @lead.email,
              phone: @lead.phone,
              account_id: account.id,
              company_id: @lead.company_id,
              location_id: location_id,
              owner_id: inherited_owner_id,
              is_primary: true,
              notes: "Converted from lead ##{@lead.id}",
              # Copy lead address → contact billing address
              street: @lead.street,
              city: @lead.city,
              state: @lead.state,
              zip: @lead.zip,
              country: @lead.country
            }
            contact_attrs[:deposit_amount] = @lead.deposit_amount if Contact.column_names.include?('deposit_amount') && @lead.deposit_amount.present?
            contact_attrs[:title] = @lead.title if @lead.try(:title).present? && Contact.column_names.include?('title')

            contact = Contact.new(contact_attrs)

            if contact.save
              Rails.logger.info "✅ [ConvertLead] Contact created: #{contact.id}"
            else
              Rails.logger.warn "⚠️  [ConvertLead] Contact creation failed: #{contact.errors.full_messages}"
              contact = nil
            end
          else
            Rails.logger.info "⏭️  [ConvertLead] Skipping contact creation (not requested)"
          end

          # 2b. CREATE CO-APPLICANT CONTACT (co-borrower) — a second contact on
          # the same account. Only when the lead captured co-applicant identity.
          co_applicant = nil
          if @lead.respond_to?(:co_applicant_first_name) &&
             (@lead.co_applicant_first_name.present? || @lead.co_applicant_last_name.present?)
            Rails.logger.info "✅ [ConvertLead] Creating co-applicant contact"

            co_applicant = Contact.new(
              first_name: @lead.co_applicant_first_name.presence || 'Co-Applicant',
              last_name:  @lead.co_applicant_last_name,
              email:      @lead.co_applicant_email,
              phone:      @lead.co_applicant_phone,
              account_id: account.id,
              company_id: @lead.company_id,
              location_id: location_id,
              owner_id:   inherited_owner_id,
              is_primary: false,
              notes: "Co-applicant converted from lead ##{@lead.id}",
              # Share the household address with the primary applicant
              street: @lead.street, city: @lead.city, state: @lead.state,
              zip: @lead.zip, country: @lead.country
            )

            if co_applicant.save
              Rails.logger.info "✅ [ConvertLead] Co-applicant contact created: #{co_applicant.id}"
            else
              Rails.logger.warn "⚠️  [ConvertLead] Co-applicant creation failed: #{co_applicant.errors.full_messages}"
              co_applicant = nil
            end
          end

          # 3. CREATE DEAL (if requested)
          deal = nil
          deal_error = nil
          if deal_params.present? && (deal_params.is_a?(ActionController::Parameters) || deal_params.is_a?(Hash))

            Rails.logger.info "✅ [ConvertLead] Creating deal with params: #{deal_params.inspect}"

            # Stage must be one the company actually configured, otherwise the
            # Deal stage validation rejects it and the deal is silently dropped.
            # Honor a valid requested stage; fall back to the company default.
            requested_stage = deal_params[:stage].to_s.strip
            stage = @company.valid_pipeline_stage?(requested_stage) ?
              requested_stage.downcase : @company.default_deal_stage
            Rails.logger.info "✅ [ConvertLead] Resolved deal stage: #{stage} (requested: #{requested_stage.presence || 'none'})"

            deal = Deal.new(
              name: deal_params[:name].presence || "#{account_name} Opportunity",
              account_id: account.id,
              contact_id: contact&.id,
              # Point the deal at the co-applicant Contact built just above, so
              # the co-borrower is visible from the deal and not only from the
              # account. nil when the lead captured no co-applicant.
              co_applicant_contact_id: co_applicant&.id,
              company_id: @lead.company_id,
              location_id: location_id,
              stage: stage,
              value: 0, # Will be updated when products/pricing added to deal
              expected_close_date: deal_params[:close_date] || deal_params[:expected_close],
              owner_id: inherited_owner_id,
              user_id: inherited_owner_id,
              description: deal_params[:description] || "Converted from lead ##{@lead.id}",
              vehicle_id: @lead.vehicle_id,  # Carry over vehicle from lead
              # Deposit carried forward from lead qualification
              down_payment: @lead.deposit_amount,
              # Copy lead address → deal billing address
              billing_street: @lead.street,
              billing_city: @lead.city,
              billing_state: @lead.state,
              billing_zip: @lead.zip,
              billing_country: @lead.country
            )

            if deal.save
              Rails.logger.info "✅ [ConvertLead] Deal created: #{deal.id}"
            else
              deal_error = deal.errors.full_messages.join(', ')
              Rails.logger.warn "⚠️  [ConvertLead] Deal creation failed: #{deal_error}"
              deal = nil
            end
          else
            Rails.logger.info "⏭️  [ConvertLead] Skipping deal creation (not requested)"
          end

          # 4. MIGRATE ACTIVITIES
          if defined?(LeadActivity) && defined?(AccountActivity)
            activity_count = @lead.lead_activities.count
            Rails.logger.info "🔄 [ConvertLead] Migrating #{activity_count} activities"

            @lead.lead_activities.each { |la| LeadConversionCarry.copy_activity(la, account: account, lead: @lead) }

            Rails.logger.info "✅ [ConvertLead] Migrated #{activity_count} activities"
          end

          # 4b. TAGS, NOTES AND OPEN FOLLOW-UPS
          LeadConversionCarry.call(lead: @lead, account: account, reused_account: !account.previously_new_record?)

          # 5. COPY CUSTOM FIELD VALUES VIA MIGRATION MAPPINGS
          cf_result = CustomFieldMigrationService.copy_values(
            @lead, contact: contact, account: account, deal: deal
          )
          Rails.logger.info "🔄 [ConvertLead] Custom field migration: copied=#{cf_result[:copied]}, gaps=#{cf_result[:gaps].size}"

          # 5b. CARRY MARKETING CONSENT FORWARD
          # Consent belongs to the person, not to the row that held them.
          # Without this the converted contact holds no consent record, and
          # Campaigns::CampaignSender gates on exactly that: converting a
          # consenting lead would quietly make them unmailable.
          carried = MarketingConsentTransfer.call(from: @lead, to: contact) +
                    MarketingConsentTransfer.call(from: @lead, to: account)
          Rails.logger.info "🔄 [ConvertLead] Marketing consent carried forward: #{carried} preference(s)"

          # 5c. CARRY TRUEBUILD DESIGNS AND THE BUYER'S PORTAL LOGIN FORWARD
          Truebuild::ConversionCarry.call(lead: @lead, contact: contact, account: account, deal: deal)

          # 5d. CARRY FOLLOWERS FORWARD (backlog E86). No notices: they were
          # already following this person.
          follower_ids = @lead.follower_ids_list
          [account, contact, deal].compact.each { |rec| rec.add_followers!(follower_ids, by: @user) }

          # 6. MARK LEAD AS CONVERTED
          @lead.update!(
            is_converted: true,
            converted_at: Time.current,
            converted_account_id: account.id
          )


      Result.new(account: account, contact: contact, co_applicant: co_applicant, deal: deal,
                 deal_error: deal_error, custom_field_gaps: cf_result[:gaps])
    end
  end
end
