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
  description: 'Notify the lead owner when a new lead is captured from Facebook.',
  entity_type: 'Lead',
  status: 'active',
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
          'to' => '{{entity.owner_email}}',
          'subject' => 'New Facebook Lead: {{entity.first_name}} {{entity.last_name}}',
          'body' => "You have a new lead from Facebook that needs follow-up.\n\n" \
            "Name: {{entity.first_name}} {{entity.last_name}}\n" \
            "Email: {{entity.email}}\n" \
            "Phone: {{entity.phone}}\n" \
            "Source: {{entity.source}}\n\n" \
            "Facebook leads have a short shelf life — try to make contact within the first 5 minutes for the best chance of converting.\n\n" \
            "Quick actions:\n" \
            "- Call them now at {{entity.phone}}\n" \
            "- Reply to their email at {{entity.email}}\n\n" \
            "Log in to view the full lead details and assign follow-up tasks."
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
          'subject' => 'Deal Closed — {{entity.name}}',
          'body' => "A deal has officially been marked as closed-won. Here are the details:\n\n" \
            "Deal: {{entity.name}}\n" \
            "Sale Amount: {{entity.amount}}\n" \
            "Closed By: {{entity.owner_name}}\n" \
            "Customer: {{entity.account_name}}\n\n" \
            "Next steps to keep things moving:\n" \
            "- Confirm all signed agreements are uploaded to the deal record\n" \
            "- Verify financing details and deposit status\n" \
            "- Coordinate delivery timeline with the operations team\n" \
            "- Schedule a welcome call with the customer\n\n" \
            "Congratulations to {{entity.owner_name}} and the entire team!"
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
          'subject' => 'Your service request has been received — Ticket #{{entity.id}}',
          'body' => "Hi {{entity.contact_first_name}},\n\n" \
            "Thank you for submitting your service request. We want you to know it has been received and logged in our system.\n\n" \
            "Ticket Number: \#{{entity.id}}\n" \
            "Subject: {{entity.subject}}\n" \
            "Status: Open — Awaiting Assignment\n\n" \
            "What happens next:\n" \
            "- A team member will review your request and reach out to schedule a time that works for you\n" \
            "- For routine requests, we typically respond within 1 business day\n" \
            "- You can reply to this email at any time to add details or photos\n\n" \
            "If this is an emergency (water leak, gas smell, electrical hazard, or no heat), please call our office immediately rather than waiting for an email response.\n\n" \
            "We appreciate your patience and will be in touch soon.\n\n" \
            "Best regards,\n" \
            "The Service Team"
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
          'subject' => 'Thanks for reaching out, {{entity.first_name}} — here is what to expect',
          'body' => "Hi {{entity.first_name}},\n\n" \
            "Thank you for your interest in our community! We received your inquiry through Facebook and wanted to personally welcome you.\n\n" \
            "Here is a little about what we offer:\n" \
            "- New and pre-owned manufactured homes in a variety of floor plans\n" \
            "- Affordable financing options and move-in specials\n" \
            "- A friendly, well-maintained community with great amenities\n\n" \
            "A member of our sales team will be reaching out shortly to learn more about what you are looking for. In the meantime, feel free to reply to this email with any questions — we are happy to help.\n\n" \
            "We look forward to connecting with you!\n\n" \
            "Warm regards,\n" \
            "The Sales Team"
        }
      },
      { 'id' => 'n2', 'type' => 'wait', 'config' => { 'duration' => 2, 'unit' => 'days' } },
      {
        'id' => 'n3',
        'type' => 'send_email',
        'config' => {
          'to' => '{{entity.email}}',
          'subject' => '{{entity.first_name}}, still looking for the right home?',
          'body' => "Hi {{entity.first_name}},\n\n" \
            "We wanted to follow up on your recent inquiry. Finding the right home is a big decision, and we are here to make the process as easy as possible.\n\n" \
            "Here are a few ways we can help:\n" \
            "- Schedule a tour of our available homes at a time that works for you\n" \
            "- Walk you through financing options and what to expect\n" \
            "- Answer any questions about floor plans, pricing, or community details\n\n" \
            "If you would like to set up a visit, just reply to this email or give us a call. We would love to show you around.\n\n" \
            "Best,\n" \
            "The Sales Team"
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
          'subject' => '{{entity.first_name}}, we have new homes available',
          'body' => "Hi {{entity.first_name}},\n\n" \
            "It has been a little while since we last connected, and we wanted to reach out with a quick update.\n\n" \
            "We have had some new homes come available recently, including some great move-in-ready options. Pricing and availability change frequently, so if you are still exploring your options, now is a great time to take another look.\n\n" \
            "We would love to reconnect and see how we can help. Feel free to:\n" \
            "- Reply to this email with any questions\n" \
            "- Call us to schedule a tour\n" \
            "- Visit our website to browse current availability\n\n" \
            "No pressure at all — we just wanted to make sure you did not miss out on something that might be a perfect fit.\n\n" \
            "Hope to hear from you!\n\n" \
            "Best regards,\n" \
            "The Sales Team"
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
