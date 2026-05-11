# frozen_string_literal: true

# Polls Champion's Retailer API for leads and upserts them into the local CRM.
#
# Runs every 15 minutes via Solid Queue (see config/recurring.yml).
# Can also be triggered manually from the Champion Lead Feed config UI.
#
# Champion FAQ notes:
#   - Contact info (email/phone) is NULL until the lead is accepted
#   - Data may take up to 15 minutes to appear due to caching
#   - Accept/decline are idempotent (always return 200)
#   - Poll interval: every 15 minutes recommended
class ChampionLeadSyncJob < ApplicationJob
  queue_as :default

  # @param config_id [Integer, nil] sync a specific config; nil = sync all active
  def perform(config_id = nil)
    configs = if config_id
                ChampionLeadFeedConfig.where(id: config_id, active: true)
              else
                ChampionLeadFeedConfig.active
              end

    configs.find_each do |config|
      sync_one(config)
    rescue => e
      Rails.logger.error "[ChampionLeadSync] Unhandled error for config #{config.id}: #{e.class} — #{e.message}"
      config.record_sync_failure!("#{e.class}: #{e.message}")
    end
  end

  private

  def sync_one(config)
    started_at = Time.current
    client     = ChampionLeadsApiClient.new(config)
    company    = config.company

    # Use paginated /leads endpoint (returns proper JSON objects).
    # The /download endpoint returns CSV-style arrays which need conversion.
    all_leads = []
    page = 1
    loop do
      result = client.list_leads(page: page, page_size: 100)

      unless result[:success]
        config.record_sync_failure!(result[:error])
        Rails.logger.error "[ChampionLeadSync] Config #{config.id} (#{config.display_label}): #{result[:error]}"
        return
      end

      batch = Array.wrap(result[:data])
      break if batch.empty?

      all_leads.concat(batch)
      break if batch.size < 100 # last page

      page += 1
      break if page > 50 # safety cap
    end

    leads_data = all_leads

    created = 0
    updated = 0
    skipped = 0
    errors  = 0

    leads_data.each do |champion_lead|
      sf_id = champion_lead['salesforceId']
      next(skipped += 1) if sf_id.blank?

      existing = company.leads.find_by(champion_salesforce_id: sf_id)

      if existing
        update_existing_lead(existing, champion_lead)
        updated += 1
      else
        create_new_lead(company, champion_lead, config)
        created += 1
      end
    rescue => e
      errors += 1
      Rails.logger.error "[ChampionLeadSync] Error on lead #{sf_id}: #{e.message}"
    end

    duration_ms = ((Time.current - started_at) * 1000).round

    stats = { created: created, updated: updated, skipped: skipped,
              errors: errors, total: leads_data.size, duration_ms: duration_ms }

    config.record_sync_success!(stats)

    Rails.logger.info "[ChampionLeadSync] Config #{config.id}: #{stats.inspect}"

    # Broadcast toast notifications for newly created leads
    broadcast_new_leads(company, created) if created > 0
  end

  # ------------------------------------------------------------------
  # Lead creation
  # ------------------------------------------------------------------

  def create_new_lead(company, data, config)
    contact    = data['leadContactInfo'] || {}
    build      = data['buildDetails'] || {}
    additional = data['additionalDetails'] || {}
    accepted   = data['acceptedDetails']

    # Parse "Monica Walker" → first_name: "Monica", last_name: "Walker"
    name_parts = (contact['name'] || '').split(' ', 2)
    first_name = name_parts[0].presence || 'Champion'
    last_name  = name_parts[1].presence || 'Lead'

    lead = company.leads.build(
      first_name:              first_name,
      last_name:               last_name,
      email:                   contact['email'],  # null until accepted
      phone:                   contact['phone'],  # null until accepted
      source_id:                find_or_create_source(company),
      status:                  map_status(data['status']),
      champion_salesforce_id:  data['salesforceId'],
      champion_status:         data['status'],
      champion_lead_data:      data,
      champion_config_id:      config.id,
      champion_accepted_at:    accepted&.dig('acceptedDateTime'),
      notes:                   build_notes(data),
      location_id:             config.location_id,
      owner_id:                resolve_default_owner(config),
      purchase_timeframe:      additional['timing'],
      interests_requirements:  build_interests(additional)
    )

    lead.save!

    lead.update_columns(
      champion_action_token:            SecureRandom.urlsafe_base64(32),
      champion_action_token_expires_at: 72.hours.from_now
    )
  end

  # ------------------------------------------------------------------
  # Lead update
  # ------------------------------------------------------------------

  def update_existing_lead(lead, data)
    contact  = data['leadContactInfo'] || {}
    accepted = data['acceptedDetails']
    declined = data['declinedDetails']

    attrs = {
      champion_status:    data['status'],
      champion_lead_data: data
    }

    # Fill in contact info once the lead has been accepted on Champion's side
    attrs[:email] = contact['email'] if contact['email'].present? && lead.email.blank?
    attrs[:phone] = contact['phone'] if contact['phone'].present? && lead.phone.blank?

    # Track acceptance
    if accepted && lead.champion_accepted_at.nil?
      attrs[:champion_accepted_at] = accepted['acceptedDateTime']
      attrs[:status] = 'contacted' unless lead.status.in?(%w[qualified proposal won converted])
    end

    # Track decline
    if declined && lead.champion_declined_at.nil?
      attrs[:champion_declined_at] = declined['declinedDateTime']
      attrs[:status] = 'lost' unless lead.status.in?(%w[won converted])
    end

    lead.update!(attrs)
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  # Map Champion status → CRM status
  def map_status(champion_status)
    case champion_status
    when 'new'      then 'new'
    when 'active'   then 'contacted'
    when 'declined' then 'lost'
    else 'new'
    end
  end

  def build_notes(data)
    build      = data['buildDetails'] || {}
    additional = data['additionalDetails'] || {}
    comment    = additional.dig('customerComment', 'text')
    care       = additional.dig('customerCareComment', 'text')

    lines = []
    lines << "🏠 Champion Lead — #{data['status']&.upcase}"
    lines << "Model: #{build['modelName']}" if build['modelName'].present?
    lines << "Manufacturer: #{build['manufacturer']}" if build['manufacturer'].present?
    lines << "Plant: #{build['plantName']}" if build['plantName'].present?
    lines << "Build Location: #{build['buildCity']}, #{build['buildState']}" if build['buildCity'].present?
    lines << "Model URL: #{build['modelUrl']}" if build['modelUrl'].present?
    lines << ""
    lines << "Timing: #{additional['timing']}" if additional['timing'].present?
    lines << "Home Placement: #{additional['homePlacement']}" if additional['homePlacement'].present?
    lines << "Financing: #{additional['hasFinancing']}" if additional['hasFinancing'].present?
    lines << ""
    lines << "Customer Comment: #{comment}" if comment.present?
    lines << "Customer Care Note: #{care}" if care.present?

    lines.reject(&:blank?).join("\n").strip
  end

  def build_interests(additional)
    parts = []
    parts << "Timing: #{additional['timing']}" if additional['timing'].present?
    parts << "Placement: #{additional['homePlacement']}" if additional['homePlacement'].present?
    parts << "Financing: #{additional['hasFinancing']}" if additional['hasFinancing'].present?
    parts.join('; ')
  end

  # Find or create a "Champion Leads" source for the company
  def find_or_create_source(company)
    @source_cache ||= {}
    @source_cache[company.id] ||= begin
      source = Source.find_or_create_by!(company_id: company.id, name: 'Champion Leads') do |s|
        s.source_type = 'api' if s.respond_to?(:source_type=)
      end
      source.id
    end
  end

  # Resolve the default owner for new champion leads.
  # Priority: config.default_lead_owner_id → first company admin → nil
  def resolve_default_owner(config)
    @owner_cache ||= {}
    @owner_cache[config.id] ||= begin
      if config.default_lead_owner_id.present?
        config.default_lead_owner_id
      else
        # Fall back to first admin user
        admin = config.company.users
                      .where(role: %w[company_admin admin])
                      .order(:created_at)
                      .first
        admin&.id
      end
    end
  end

  # Broadcast a single ActionCable toast (not one per lead)
  def broadcast_new_leads(company, count)
    label = count == 1 ? '1 New Champion Lead' : "#{count} New Champion Leads"

    company.users.where(is_active: true).find_each do |user|
      ActionCable.server.broadcast(
        "user_notifications_#{user.id}",
        {
          type: 'champion_lead',
          activity: {
            type: 'champion_lead_received',
            subject: label,
            priority: 'high',
            entityType: 'lead',
            entityName: label
          }
        }
      )
    end
  rescue => e
    Rails.logger.warn "[ChampionLeadSync] Broadcast error: #{e.message}"
  end
end
