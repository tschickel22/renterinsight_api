puts "⚙️  Seeding DMS Workflows..."

target_companies = if ENV['WORKFLOW_SEED_COMPANY_ID'].present?
                     Company.where(id: ENV['WORKFLOW_SEED_COMPANY_ID'])
                   else
                     Company.all
                   end

if target_companies.empty?
  puts "   ⚠️  No companies found. Skipping workflow seeds."
  return
end

new_lead_alert = {
  name: 'New Lead Alert',
  description: 'Notify the lead owner whenever a new lead is created.',
  entity_type: 'Lead',
  status: 'active',
  trigger: { 'event_type' => 'lead.created', 'entity_type_filter' => 'Lead' },
  conditions: [],
  steps: {
    'nodes' => [
      {
        'id' => 'n1',
        'type' => 'send_email',
        'config' => {
          'to' => '{{entity.owner_email}}',
          'subject' => 'New Lead: {{entity.first_name}} {{entity.last_name}}',
          'body' => "A new lead has been added.\n\nName: {{entity.first_name}} {{entity.last_name}}\nEmail: {{entity.email}}\nPhone: {{entity.phone}}\nSource: {{entity.source}}\n\nLog in to follow up."
        }
      }
    ],
    'edges' => []
  },
  parameters: {}
}

deal_closed_notification = {
  name: 'Deal Closed Notification',
  description: 'Notify the deal owner when a deal is marked closed_won.',
  entity_type: 'Deal',
  status: 'active',
  trigger: { 'event_type' => 'deal.status_changed', 'entity_type_filter' => 'Deal' },
  conditions: [
    {
      'type' => 'and',
      'conditions' => [
        { 'field' => 'stage', 'operator' => 'equals', 'value' => 'closed_won' }
      ]
    }
  ],
  steps: {
    'nodes' => [
      {
        'id' => 'n1',
        'type' => 'send_email',
        'config' => {
          'to' => '{{entity.owner_email}}',
          'subject' => 'Deal Closed: {{entity.name}}',
          'body' => "Great news! A deal has been closed.\n\nDeal: {{entity.name}}\nAmount: {{entity.amount}}\nClosed by: {{entity.owner_name}}\nAccount: {{entity.account_name}}\n\nCongratulations!"
        }
      }
    ],
    'edges' => []
  },
  parameters: {}
}

service_ticket_acknowledgment = {
  name: 'Service Ticket Acknowledgment',
  description: 'Send the customer an acknowledgment email when they open a service ticket.',
  entity_type: 'ServiceTicket',
  status: 'active',
  trigger: { 'event_type' => 'service_ticket.created', 'entity_type_filter' => 'ServiceTicket' },
  conditions: [],
  steps: {
    'nodes' => [
      {
        'id' => 'n1',
        'type' => 'send_email',
        'config' => {
          'to' => '{{entity.contact_email}}',
          'subject' => 'We received your service request - Ticket #{{entity.id}}',
          'body' => "Hi {{entity.contact_first_name}},\n\nThank you for reaching out. We received your service request and our team is reviewing it.\n\nTicket: \#{{entity.id}}\nSubject: {{entity.subject}}\n\nWe will follow up shortly. If urgent, please call our office.\n\nThank you,\nThe Management Team"
        }
      }
    ],
    'edges' => []
  },
  parameters: {}
}

facebook_lead_welcome = {
  name: 'Facebook Lead Welcome Sequence',
  description: 'Multi-step welcome series for leads sourced from Facebook.',
  entity_type: 'Lead',
  status: 'draft',
  trigger: { 'event_type' => 'lead.created', 'entity_type_filter' => 'Lead' },
  conditions: [
    {
      'type' => 'and',
      'conditions' => [
        { 'field' => 'source', 'operator' => 'equals', 'value' => 'Facebook' }
      ]
    }
  ],
  steps: {
    'nodes' => [
      {
        'id' => 'n1',
        'type' => 'send_email',
        'config' => {
          'to' => '{{entity.email}}',
          'subject' => 'Welcome, {{entity.first_name}}!',
          'body' => "Hi {{entity.first_name}},\n\nThanks for your interest! We saw you reached out through Facebook and we're excited to help.\n\nA team member will be in touch soon. In the meantime, feel free to reply with any questions.\n\nCheers,\nThe Team"
        }
      },
      { 'id' => 'n2', 'type' => 'wait', 'config' => { 'duration' => 2, 'unit' => 'days' } },
      {
        'id' => 'n3',
        'type' => 'send_email',
        'config' => {
          'to' => '{{entity.email}}',
          'subject' => 'Following up, {{entity.first_name}}',
          'body' => "Hi {{entity.first_name}},\n\nJust checking in to see if you had any questions we can help answer. Reply to this email anytime — we read every message.\n\nTalk soon,\nThe Team"
        }
      },
      { 'id' => 'n4', 'type' => 'wait', 'config' => { 'duration' => 3, 'unit' => 'days' } },
      {
        'id' => 'n5',
        'type' => 'create_activity',
        'config' => {
          'activity_type' => 'call',
          'subject' => 'Call Facebook lead: {{entity.first_name}} {{entity.last_name}}',
          'description' => 'Welcome sequence complete — make a personal outreach call.',
          'due_in_hours' => 24,
          'assigned_to' => 'owner'
        }
      }
    ],
    'edges' => [
      { 'id' => 'e_n1_n2', 'source' => 'n1', 'target' => 'n2' },
      { 'id' => 'e_n2_n3', 'source' => 'n2', 'target' => 'n3' },
      { 'id' => 'e_n3_n4', 'source' => 'n3', 'target' => 'n4' },
      { 'id' => 'e_n4_n5', 'source' => 'n4', 'target' => 'n5' }
    ]
  },
  parameters: {}
}

reengage_stale_leads = {
  name: 'Re-engage Stale Leads',
  description: 'Daily sweep for stale leads — sends a re-engagement email, tags, and creates a follow-up task.',
  entity_type: 'Lead',
  status: 'draft',
  trigger: { 'event_type' => 'lead.stale', 'entity_type_filter' => 'Lead' },
  conditions: [],
  steps: {
    'nodes' => [
      {
        'id' => 'n1',
        'type' => 'send_email',
        'config' => {
          'to' => '{{entity.email}}',
          'subject' => 'Still interested, {{entity.first_name}}?',
          'body' => "Hi {{entity.first_name}},\n\nIt's been a while since we last connected. Are you still in the market? Reply with a quick yes or no and we'll take it from there.\n\nThanks,\nThe Team"
        }
      },
      { 'id' => 'n2', 'type' => 'add_tag', 'config' => { 'tag_names' => ['stale-notified'] } },
      {
        'id' => 'n3',
        'type' => 'create_activity',
        'config' => {
          'activity_type' => 'task',
          'subject' => 'Re-engagement follow-up: {{entity.first_name}} {{entity.last_name}}',
          'description' => 'Lead was emailed via the Re-engage Stale Leads workflow. Follow up if no reply.',
          'due_in_hours' => 72,
          'assigned_to' => 'owner'
        }
      }
    ],
    'edges' => [
      { 'id' => 'e_n1_n2', 'source' => 'n1', 'target' => 'n2' },
      { 'id' => 'e_n2_n3', 'source' => 'n2', 'target' => 'n3' }
    ]
  },
  parameters: {}
}

hot_lead_sms = {
  name: 'Hot Lead SMS Alert',
  description: 'Text the lead owner the moment a lead crosses the hot-score threshold.',
  entity_type: 'Lead',
  status: 'draft',
  trigger: { 'event_type' => 'lead.updated', 'entity_type_filter' => 'Lead' },
  conditions: [
    {
      'type' => 'and',
      'conditions' => [
        { 'field' => 'health_score', 'operator' => 'greater_than_or_equal', 'value' => 80 }
      ]
    }
  ],
  steps: {
    'nodes' => [
      {
        'id' => 'n1',
        'type' => 'send_sms',
        'config' => {
          'to' => '{{entity.owner_phone}}',
          'body' => 'HOT LEAD: {{entity.first_name}} {{entity.last_name}} ({{entity.phone}}) just went hot. Call now!'
        }
      }
    ],
    'edges' => []
  },
  parameters: {}
}

WORKFLOW_DEFINITIONS = [
  new_lead_alert,
  deal_closed_notification,
  service_ticket_acknowledgment,
  facebook_lead_welcome,
  reengage_stale_leads,
  hot_lead_sms
].freeze

created = 0
updated = 0

target_companies.each do |company|
  WORKFLOW_DEFINITIONS.each do |attrs|
    rule = WorkflowRule.find_or_initialize_by(company_id: company.id, name: attrs[:name])
    was_new = rule.new_record?

    rule.assign_attributes(
      description: attrs[:description],
      entity_type: attrs[:entity_type],
      status: attrs[:status],
      trigger: attrs[:trigger],
      conditions: attrs[:conditions],
      steps: attrs[:steps],
      parameters: attrs[:parameters],
      is_seeded: true
    )
    rule.save!

    if was_new
      created += 1
      puts "   ✅ Created  [#{company.name}] #{rule.name} (#{rule.status})"
    else
      updated += 1
      puts "   ♻️  Updated [#{company.name}] #{rule.name} (#{rule.status})"
    end
  end
end

puts "   Done. #{created} created, #{updated} updated across #{target_companies.count} company(ies)."
