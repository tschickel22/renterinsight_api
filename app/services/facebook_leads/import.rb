# frozen_string_literal: true

module FacebookLeads
  # Pulls a connected Page's recent Lead Ads leads from Meta and adds the ones
  # the CRM doesn't have. Meta keeps a lead for 90 days, so that is as far back
  # as this reaches.
  #
  # An import is not a new inquiry, so it stays quiet:
  #   - a person already in the CRM (by Facebook lead id, email or phone) is
  #     skipped silently. The live path's repeat-inquiry handling would write a
  #     note and alert the owner for each of them.
  #   - no workflow starts. A lead play would otherwise text and email people
  #     who asked weeks ago as if they had just filled in the form.
  #   - no owner notification and no outbound webhook per lead.
  # Imported leads keep their original submission time in source_created_at.
  #
  # dry_run: counts what would happen and writes nothing.
  class Import
    WINDOW = 90.days
    MAX_ERRORS = 5

    Progress = Struct.new(:forms, :found, :already_imported, :already_in_crm, :imported, :failed,
                          :oldest, :newest, :errors, keyword_init: true) do
      def as_json(*)
        to_h.merge(oldest: oldest&.iso8601, newest: newest&.iso8601)
      end
    end

    def initialize(integration, dry_run:, on_progress: nil)
      @integration = integration
      @company = Company.find(integration.company_id)
      @dry_run = dry_run
      @on_progress = on_progress
      @builder = LeadBuilder.new(integration, @company)
      # People this run has already counted or created, so one person on two
      # forms is one lead.
      @seen_emails = Set.new
      @seen_phones = Set.new
    end

    def call
      progress = Progress.new(forms: 0, found: 0, already_imported: 0, already_in_crm: 0, imported: 0,
                              failed: 0, errors: [])
      since = WINDOW.ago
      token = @integration.page_access_token

      MetaGraphApi.each_lead_form(@integration.page_id, token) do |form|
        progress.forms += 1
        MetaGraphApi.each_form_lead(form['id'], token, since: since) do |raw|
          handle(raw, form, progress)
          @on_progress&.call(progress) if (progress.found % 25).zero?
        end
      end

      progress
    end

    private

    def handle(raw, form, progress)
      progress.found += 1
      submitted = parse_time(raw['created_time'])
      progress.oldest = submitted if submitted && (progress.oldest.nil? || submitted < progress.oldest)
      progress.newest = submitted if submitted && (progress.newest.nil? || submitted > progress.newest)

      leadgen_id = raw['id'].to_s
      if Lead.exists?(company_id: @company.id, facebook_leadgen_id: leadgen_id)
        progress.already_imported += 1
        return
      end

      built = @builder.build(raw, leadgen_id: leadgen_id, form_id: form['id'])
      attrs = built.attrs

      if seen?(attrs) || @builder.identity_match(attrs)
        progress.already_in_crm += 1
        return
      end
      remember(attrs)

      create!(attrs, built, submitted, form) unless @dry_run
      progress.imported += 1
    rescue ActiveRecord::RecordNotUnique
      progress.already_imported += 1
    rescue StandardError => e
      progress.failed += 1
      if progress.errors.size < MAX_ERRORS
        progress.errors << "Lead #{raw['id']}: #{e.class}: #{e.message}".truncate(300)
      end
      Rails.logger.error "[FacebookLeads::Import] integration=#{@integration.id} lead=#{raw['id']}: #{e.class}: #{e.message}"
    end

    def create!(attrs, built, submitted, form)
      stamp = submitted ? submitted.in_time_zone.strftime('%b %-d, %Y') : 'an unknown date'
      header = "Imported from Facebook on #{Time.current.strftime('%b %-d, %Y')}. " \
               "Submitted #{stamp} on the form \"#{form['name']}\"."
      lead = Lead.new(attrs.merge(notes: [header, attrs[:notes]].compact.join("\n\n"), source_created_at: submitted))
      lead.skip_notifications = true
      lead.skip_webhooks = true

      Current.set(suppress_workflow_events: true) do
        lead.save!
        @builder.write_answers_note(lead, built.answers)
      end
    end

    def seen?(attrs)
      email = attrs[:email].to_s.strip.downcase.presence
      phone = attrs[:phone].to_s.gsub(/\D/, '').last(10).presence
      (email && @seen_emails.include?(email)) || (phone && @seen_phones.include?(phone))
    end

    def remember(attrs)
      email = attrs[:email].to_s.strip.downcase.presence
      phone = attrs[:phone].to_s.gsub(/\D/, '').last(10).presence
      @seen_emails << email if email
      @seen_phones << phone if phone
    end

    def parse_time(value)
      value.present? ? Time.zone.parse(value.to_s) : nil
    rescue ArgumentError
      nil
    end
  end
end
