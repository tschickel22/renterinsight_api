class AiActionExecutor
  class ExecutionError < StandardError; end

  def initialize(company, user, location_id = nil)
    @company     = company
    @user        = user
    @location_id = location_id
  end

  def execute(action, params)
    raise ExecutionError, 'No company context — ensure X-Company-ID header is set' unless @company
    case action
    when 'create_lead'           then execute_create_lead(params)
    when 'create_contact'         then execute_create_contact(params)
    when 'update_lead_status'    then execute_update_lead_status(params)
    when 'update_deal_stage'     then execute_update_deal_stage(params)
    when 'assign_lead'           then execute_assign_lead(params)
    when 'create_service_ticket' then execute_create_service_ticket(params)
    when 'create_activity'       then execute_create_activity(params, action)
    when 'add_note'              then execute_add_note(params)
    else
      raise ExecutionError, "Unknown action: #{action}"
    end
  end

  private

  # ─────────────────────────────────────────────────────────────────────────
  # Shared entity finder — used by activities, notes, email drafts.
  # Returns { entity:, entity_type:, disambiguation: } hash.
  # disambiguation is non-nil when multiple matches were found.
  # ─────────────────────────────────────────────────────────────────────────
  def resolve_entity(params, action)
    entity_type = params['entity_type']&.downcase || 'lead'
    entity_id   = params['entity_id']&.to_i
    entity_name = params['entity_name'].to_s.strip

    # If ID already provided, just look it up directly
    if entity_id.present? && entity_id > 0
      entity = case entity_type
      when 'lead'    then @company.leads.find_by(id: entity_id)
      when 'contact' then @company.contacts.find_by(id: entity_id)
      when 'account' then @company.accounts.find_by(id: entity_id)
      when 'deal'    then @company.deals.find_by(id: entity_id)
      end
      return { entity: entity, entity_type: entity_type, disambiguation: nil }
    end

    return { entity: nil, entity_type: entity_type, disambiguation: nil } if entity_name.blank?

    name_parts = entity_name.split(' ', 2)
    matches = case entity_type
    when 'lead'
      exact = @company.leads.where(
        "first_name ILIKE ? AND last_name ILIKE ?", name_parts[0], name_parts[1] || '%'
      ).includes(:source, :owner).limit(10).to_a
      exact.presence || @company.leads.where(
        "first_name ILIKE ? OR last_name ILIKE ?",
        "%#{entity_name}%", "%#{entity_name}%"
      ).includes(:source, :owner).limit(10).to_a
    when 'contact'
      exact = @company.contacts.where(
        "first_name ILIKE ? AND last_name ILIKE ?", name_parts[0], name_parts[1] || '%'
      ).includes(:account).limit(10).to_a
      exact.presence || @company.contacts.where(
        "first_name ILIKE ? OR last_name ILIKE ?",
        "%#{entity_name}%", "%#{entity_name}%"
      ).includes(:account).limit(10).to_a
    when 'account'
      @company.accounts.where("name ILIKE ?", "%#{entity_name}%").limit(10).to_a
    when 'deal'
      exact = @company.deals.where("deal_number ILIKE ?", "%#{entity_name}%").limit(10).to_a
      exact.presence || @company.deals.where("name ILIKE ?", "%#{entity_name}%").limit(10).to_a
    else []
    end

    if matches.size > 1
      disambiguation = {
        success:        false,
        disambiguate:   true,
        entity_type:    entity_type,
        message:        "Found #{matches.size} #{entity_type.pluralize} named \"#{entity_name}\". Which one did you mean?",
        matches:        matches.map { |e| entity_summary(e, entity_type).merge(entity_type: entity_type) },
        pending_action: action,
        pending_params: params
      }
      return { entity: nil, entity_type: entity_type, disambiguation: disambiguation }
    end

    { entity: matches.first, entity_type: entity_type, disambiguation: nil }
  end

  # Cross-type entity search — finds any person or company by name across leads, contacts, accounts.
  # Called by create_activity and add_note so users don't have to navigate to the right page first.
  # Order: leads → contacts → accounts → deals
  def resolve_entity_with_fallback(params, action)
    entity_type = params['entity_type']&.downcase
    entity_id   = params['entity_id']&.to_i
    entity_name = params['entity_name'].to_s.strip

    # If a specific ID was given, look it up directly in the declared type (or lead as default)
    if entity_id.present? && entity_id > 0
      type = entity_type.presence || 'lead'
      entity = case type
      when 'lead'    then @company.leads.find_by(id: entity_id)
      when 'contact' then @company.contacts.find_by(id: entity_id)
      when 'account' then @company.accounts.find_by(id: entity_id)
      when 'deal'    then @company.deals.find_by(id: entity_id)
      end
      return { entity: entity, entity_type: type, disambiguation: nil }
    end

    return { entity: nil, entity_type: entity_type || 'lead', disambiguation: nil } if entity_name.blank?

    name_parts = entity_name.split(' ', 2)

    # ── If a specific type was requested by Claude AND it finds results, trust it ──
    if entity_type.present? && entity_type != 'lead'
      result = resolve_entity(params, action)
      return result if result[:entity] || result[:disambiguation]
    end

    # ── Otherwise search ALL types in priority order ──
    all_matches = []

    # 1. Leads
    lead_matches = @company.leads.where(
      "first_name ILIKE ? AND last_name ILIKE ?", name_parts[0], name_parts[1] || '%'
    ).includes(:source, :owner).limit(5).to_a
    lead_matches = @company.leads.where(
      "first_name ILIKE ? OR last_name ILIKE ?", "%#{entity_name}%", "%#{entity_name}%"
    ).includes(:source, :owner).limit(5).to_a if lead_matches.empty?
    all_matches += lead_matches.map { |e| { entity: e, entity_type: 'lead' } }

    # 2. Contacts
    contact_matches = @company.contacts.where(
      "first_name ILIKE ? AND last_name ILIKE ?", name_parts[0], name_parts[1] || '%'
    ).limit(5).to_a
    contact_matches = @company.contacts.where(
      "first_name ILIKE ? OR last_name ILIKE ?", "%#{entity_name}%", "%#{entity_name}%"
    ).limit(5).to_a if contact_matches.empty?
    all_matches += contact_matches.map { |e| { entity: e, entity_type: 'contact' } }

    # 3. Accounts
    account_matches = @company.accounts.where("name ILIKE ?", "%#{entity_name}%").limit(5).to_a
    all_matches += account_matches.map { |e| { entity: e, entity_type: 'account' } }

    return { entity: nil, entity_type: 'lead', disambiguation: nil } if all_matches.empty?

    # Single match — use it
    if all_matches.size == 1
      return { entity: all_matches.first[:entity], entity_type: all_matches.first[:entity_type], disambiguation: nil }
    end

    # Multiple matches across types — disambiguate
    disambiguation = {
      success:        false,
      disambiguate:   true,
      entity_type:    'multiple',
      message:        "Found #{all_matches.size} records named \"#{entity_name}\". Which one did you mean?",
      matches:        all_matches.map { |m| entity_summary(m[:entity], m[:entity_type]).merge(entity_type: m[:entity_type]) },
      pending_action: action,
      pending_params: params
    }
    { entity: nil, entity_type: 'lead', disambiguation: disambiguation }
  end

  def entity_summary(entity, entity_type)
    case entity_type
    when 'lead'
      { id: entity.id, name: entity.full_name, email: entity.email, phone: entity.phone,
        status: entity.status, source: entity.try(:source)&.name,
        owner: entity.try(:owner) ? "#{entity.owner.first_name} #{entity.owner.last_name}".strip : nil,
        created_at: entity.created_at&.strftime('%b %d, %Y') }
    when 'contact'
      { id: entity.id, name: "#{entity.first_name} #{entity.last_name}".strip,
        email: entity.email, phone: entity.phone,
        status: entity.try(:account)&.name,
        created_at: entity.created_at&.strftime('%b %d, %Y') }
    when 'account'
      { id: entity.id, name: entity.name, email: entity.try(:email),
        status: entity.try(:account_type),
        created_at: entity.created_at&.strftime('%b %d, %Y') }
    when 'deal'
      { id: entity.id, name: entity.try(:name) || entity.try(:deal_number) || "##{entity.id}",
        status: entity.stage,
        created_at: entity.created_at&.strftime('%b %d, %Y') }
    else
      { id: entity.id, name: entity.try(:full_name) || entity.try(:name) || "##{entity.id}" }
    end
  end

  # Returns the URL path for a given entity type + ID
  def entity_path(entity_type, id, tab: nil)
    base = case entity_type
    when 'lead'           then "/crm/leads/#{id}"
    when 'contact'        then "/contacts/#{id}"
    when 'account'        then "/accounts/#{id}"
    when 'deal'           then "/deals/#{id}"
    when 'service_ticket' then "/service/#{id}"
    when 'invoice'        then "/finance/invoices/#{id}"
    when 'quote'          then "/quotes/#{id}"
    end
    tab ? "#{base}?tab=#{tab}" : base
  end

  # ─────────────────────────────────────────────────────────────────────────
  # CRUD actions
  # ─────────────────────────────────────────────────────────────────────────

  def execute_create_lead(params)
    raw_email = params['email']&.strip&.downcase
    email = raw_email&.match?(/\A[^@\s]+@[^@\s]+\z/) ? raw_email : nil
    source_id = params['source_id'] ||
      @company.sources.where(is_active: [true, nil]).order(:id).first&.id

    lead = @company.leads.new(
      first_name:  params['first_name']&.strip,
      last_name:   params['last_name']&.strip,
      email:       email,
      phone:       params['phone'],
      notes:       [params['notes'], params['interest']].compact.reject(&:blank?).join('. ').presence,
      status:      params['status'].presence || 'new',
      source_id:   source_id,
      owner_id:    params['owner_id'] || @user&.id,
      location_id: @location_id
    )
    raise ExecutionError, "Could not create lead: #{lead.errors.full_messages.join(', ')}" unless lead.save
    {
      success: true, record: 'lead', record_id: lead.id,
      message: "Lead created: #{lead.full_name}",
      view_path: entity_path('lead', lead.id),
      data: { id: lead.id, lead_id: lead.id, name: lead.full_name,
              phone: lead.phone, email: lead.email, status: lead.status }
    }
  end

  def execute_create_contact(params)
    raw_email = params['email']&.strip&.downcase
    email = raw_email&.match?(/\A[^@\s]+@[^@\s]+\z/) ? raw_email : nil

    contact = @company.contacts.new(
      first_name:  params['first_name']&.strip,
      last_name:   params['last_name']&.strip,
      email:       email,
      phone:       params['phone'],
      notes:       params['notes'],
      location_id: @location_id
    )
    raise ExecutionError, "Could not create contact: #{contact.errors.full_messages.join(', ')}" unless contact.save
    {
      success: true, record: 'contact', record_id: contact.id,
      message: "Contact created: #{contact.first_name} #{contact.last_name}".strip,
      view_path: entity_path('contact', contact.id),
      data: { id: contact.id, contact_id: contact.id,
              name: "#{contact.first_name} #{contact.last_name}".strip,
              phone: contact.phone, email: contact.email }
    }
  end

  def execute_update_lead_status(params)
    lead = find_lead(params)
    old_status = lead.status
    raise ExecutionError, "Could not update: #{lead.errors.full_messages.join(', ')}" unless lead.update(status: params['status'])
    {
      success: true, record: 'lead', record_id: lead.id,
      message: "Lead #{lead.full_name} updated: #{old_status} → #{lead.status}",
      view_path: entity_path('lead', lead.id),
      data: { id: lead.id, lead_id: lead.id, name: lead.full_name,
              old_status: old_status, new_status: lead.status }
    }
  end

  def execute_update_deal_stage(params)
    deal = if params['deal_number'].present?
      @company.deals.find_by!(deal_number: params['deal_number'])
    elsif params['deal_id'].present?
      @company.deals.find(params['deal_id'])
    else
      raise ExecutionError, 'No deal identifier provided'
    end
    update_attrs = { stage: params['stage'] }
    update_attrs[:selling_price] = params['selling_price'] if params['selling_price'].present?
    update_attrs[:value]         = params['selling_price'] if params['selling_price'].present?
    old_stage = deal.stage
    raise ExecutionError, "Could not update deal: #{deal.errors.full_messages.join(', ')}" unless deal.update(update_attrs)
    {
      success: true, record: 'deal', record_id: deal.id,
      message: "Deal #{deal.deal_number} updated: #{old_stage} → #{deal.stage}#{params['selling_price'].present? ? " at $#{params['selling_price']}" : ''}",
      view_path: entity_path('deal', deal.id),
      data: { id: deal.id, deal_id: deal.id, deal_number: deal.deal_number,
              old_stage: old_stage, new_stage: deal.stage }
    }
  end

  def execute_assign_lead(params)
    lead  = find_lead(params)
    owner = @company.users.find(params['owner_id'])
    raise ExecutionError, lead.errors.full_messages.join(', ') unless lead.update(owner_id: owner.id, skip_notifications: true)
    {
      success: true, record: 'lead', record_id: lead.id,
      message: "Lead #{lead.full_name} assigned to #{owner.first_name} #{owner.last_name}",
      view_path: entity_path('lead', lead.id),
      data: { id: lead.id, lead_id: lead.id, name: lead.full_name,
              assigned_to: owner.first_name }
    }
  end

  def execute_create_service_ticket(params)
    ticket = @company.service_tickets.new(
      title:       params['title'],
      description: params['description'].presence || params['title'],
      priority:    params['priority'].presence || 'medium',
      status:      params['status'].presence || 'open',
      assigned_to: @user&.id&.to_s,
      location_id: @location_id
    )
    raise ExecutionError, "Could not create ticket: #{ticket.errors.full_messages.join(', ')}" unless ticket.save
    {
      success: true, record: 'service_ticket', record_id: ticket.id,
      message: "Service ticket created: #{ticket.ticket_number} — #{ticket.title}",
      view_path: entity_path('service_ticket', ticket.id),
      data: { id: ticket.id, ticket_id: ticket.id, ticket_number: ticket.ticket_number,
              title: ticket.title, priority: ticket.priority }
    }
  end

  def execute_create_activity(params, action = 'create_activity')
    # Resolve entity — uses fallback so if 'lead' not found, tries contacts then accounts
    resolved = resolve_entity_with_fallback(params, action)
    return resolved[:disambiguation] if resolved[:disambiguation]

    entity      = resolved[:entity]
    entity_type = resolved[:entity_type]
    return { success: false, message: "Could not find anyone named \"#{params['entity_name']}\"" } unless entity

    # Normalize activity_type — valid: task meeting call reminder note
    raw_type = params['activity_type'].to_s.downcase.strip
    activity_type = case raw_type
    when 'task', 'todo', 'to-do', 'follow_up', 'follow-up', 'followup' then 'task'
    when 'meeting', 'appointment', 'visit'                              then 'meeting'
    when 'call', 'phone', 'phone_call'                                  then 'call'
    when 'reminder', 'remind'                                           then 'reminder'
    else 'note'
    end

    # Normalize status
    raw_status = params['status'].to_s.downcase.strip
    status = case raw_status
    when 'pending', 'open', 'new', 'todo'                      then 'pending'
    when 'in_progress', 'in-progress', 'active', 'started'     then 'in_progress'
    when 'completed', 'complete', 'done', 'finished', 'closed' then 'completed'
    when 'cancelled', 'canceled'                               then 'cancelled'
    else %w[task reminder meeting].include?(activity_type) ? 'pending' : 'completed'
    end

    raw_priority = params['priority'].to_s.downcase.strip
    priority = %w[low medium high urgent].include?(raw_priority) ? raw_priority : 'medium'

    due_date = reminder_time = nil
    if params['due_in_days'].present? && params['due_in_days'].to_i > 0
      due_date = params['due_in_days'].to_i.days.from_now.beginning_of_day + 9.hours
      reminder_time = due_date
    elsif params['due_date'].present?
      due_date = Time.parse(params['due_date']) rescue nil
    end

    # Route to the correct activity model based on entity type
    case entity_type
    when 'lead'
      create_lead_activity(entity, activity_type, status, priority, due_date, reminder_time, params)
    when 'contact'
      create_contact_activity(entity, activity_type, status, priority, due_date, reminder_time, params)
    when 'account'
      create_account_activity(entity, activity_type, status, priority, due_date, reminder_time, params)
    else
      { success: false, message: "Activities for #{entity_type} are not yet supported" }
    end
  end

  def create_lead_activity(lead, activity_type, status, priority, due_date, reminder_time, params)
    activity = LeadActivity.new(
      lead_id:        lead.id,
      user_id:        @user&.id || lead.owner_id || @company.users.first&.id,
      assigned_to_id: @user&.id,
      activity_type:  activity_type,
      subject:        params['subject'].presence || build_subject(activity_type, lead, params),
      description:    params['notes'] || params['description'],
      status:         status,
      priority:       priority,
      due_date:       due_date,
      reminder_time:  reminder_time
    )
    raise ExecutionError, "Could not log activity: #{activity.errors.full_messages.join(', ')}" unless activity.save
    due_label = due_date ? " — due #{due_date.strftime('%b %d, %Y')}" : ''
    { success: true, record: 'activity', record_id: activity.id,
      message: "#{activity_type.titleize} logged for #{lead.full_name} (#{status}#{due_label})",
      view_path: entity_path('lead', lead.id, tab: 'activities'),
      data: { id: activity.id, lead_id: lead.id, entity_type: 'lead', entity_id: lead.id,
              type: activity.activity_type, subject: activity.subject, status: activity.status } }
  end

  def create_contact_activity(contact, activity_type, status, priority, due_date, reminder_time, params)
    entity_name = "#{contact.first_name} #{contact.last_name}".strip
    activity = ContactActivity.new(
      contact_id:     contact.id,
      user_id:        @user&.id || @company.users.first&.id,
      assigned_to_id: @user&.id,
      activity_type:  activity_type,
      subject:        params['subject'].presence || build_subject(activity_type, contact, params),
      description:    params['notes'] || params['description'],
      status:         status,
      priority:       priority,
      due_date:       due_date,
      reminder_time:  reminder_time
    )
    raise ExecutionError, "Could not log activity: #{activity.errors.full_messages.join(', ')}" unless activity.save
    due_label = due_date ? " — due #{due_date.strftime('%b %d, %Y')}" : ''
    { success: true, record: 'activity', record_id: activity.id,
      message: "#{activity_type.titleize} logged for #{entity_name} (#{status}#{due_label})",
      view_path: entity_path('contact', contact.id, tab: 'activities'),
      data: { id: activity.id, contact_id: contact.id, entity_type: 'contact', entity_id: contact.id,
              type: activity.activity_type, subject: activity.subject, status: activity.status } }
  end

  def create_account_activity(account, activity_type, status, priority, due_date, reminder_time, params)
    activity = AccountActivity.new(
      account_id:     account.id,
      user_id:        @user&.id || @company.users.first&.id,
      assigned_to_id: @user&.id,
      activity_type:  activity_type,
      subject:        params['subject'].presence || build_subject(activity_type, account, params),
      description:    params['notes'] || params['description'],
      status:         status,
      priority:       priority,
      due_date:       due_date,
      reminder_time:  reminder_time
    )
    raise ExecutionError, "Could not log activity: #{activity.errors.full_messages.join(', ')}" unless activity.save
    due_label = due_date ? " — due #{due_date.strftime('%b %d, %Y')}" : ''
    { success: true, record: 'activity', record_id: activity.id,
      message: "#{activity_type.titleize} logged for #{account.name} (#{status}#{due_label})",
      view_path: entity_path('account', account.id, tab: 'activities'),
      data: { id: activity.id, account_id: account.id, entity_type: 'account', entity_id: account.id,
              type: activity.activity_type, subject: activity.subject, status: activity.status } }
  end

  def build_subject(activity_type, entity, params)
    context = params['notes'].to_s.truncate(60).presence
    name = entity.try(:full_name) || entity.try(:name) || 'Unknown'
    case activity_type
    when 'note'     then context || "Note for #{name}"
    when 'call'     then "Call with #{name}"
    when 'task'     then context || "Follow up with #{name}"
    when 'reminder' then context || "Reminder: #{name}"
    when 'meeting'  then "Meeting with #{name}"
    else "Activity for #{name}"
    end
  end

  def execute_add_note(params)
    # Resolve entity across all types — user can say any name from any page
    resolved = resolve_entity_with_fallback(params, 'add_note')
    return resolved[:disambiguation] if resolved[:disambiguation]

    entity      = resolved[:entity]
    entity_type = resolved[:entity_type]
    entity_name = params['entity_name'].to_s.strip

    return { success: false, message: "Could not find anyone named \"#{entity_name}\"" } unless entity

    case entity_type
    when 'lead'
      existing = entity.notes.to_s
      entity.update!(notes: [existing, params['note']].reject(&:blank?).join("\n\n"))
    when 'contact'
      existing = entity.notes.to_s
      entity.update!(notes: [existing, params['note']].reject(&:blank?).join("\n\n"))
    when 'account'
      existing = entity.notes.to_s
      entity.update!(notes: [existing, params['note']].reject(&:blank?).join("\n\n"))
    else
      return { success: false, message: "Adding notes to #{entity_type} is not yet supported" }
    end

    { success: true, record: entity_type, record_id: entity.id,
      message: 'Note added successfully',
      view_path: entity_path(entity_type, entity.id),
      data: { entity_type: entity_type, entity_id: entity.id } }
  rescue ActiveRecord::RecordNotFound
    { success: false, message: "Record not found" }
  end

  def find_lead(params)
    if params['lead_id'].present?
      @company.leads.find(params['lead_id'])
    elsif params['lead_name'].present?
      parts = params['lead_name'].split(' ', 2)
      @company.leads.find_by!("first_name ILIKE ? AND last_name ILIKE ?", parts[0], parts[1] || '%')
    else
      raise ExecutionError, 'No lead identifier provided'
    end
  rescue ActiveRecord::RecordNotFound
    raise ExecutionError, "Lead not found"
  end
end
