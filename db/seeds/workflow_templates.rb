# Idempotent seed for workflow templates (global - no company_id)

def linear_edges(node_ids)
  node_ids.each_cons(2).map { |a, b| { 'id' => "e_#{a}_#{b}", 'source' => a, 'target' => b } }
end

def upsert_template(key, attrs)
  t = WorkflowTemplate.find_or_create_by!(key: key) { |r| r.assign_attributes(attrs) }
  t.update!(attrs)
  t
end

templates = []

# (1) welcome_new_lead
templates << {
  key: 'welcome_new_lead',
  name: 'Welcome New Lead',
  category: 'Lead Follow-up',
  entity_type: 'Lead',
  icon: 'UserPlus',
  description: 'Automatically welcome new leads with a multi-step email and call sequence.',
  preview_description: 'Sends a welcome email immediately, follows up a couple of days later, then schedules a call task. A great starter workflow for any new lead.',
  required_integrations: [],
  trigger: { 'event_type' => 'lead.created', 'entity_type_filter' => 'Lead' },
  conditions: [],
  steps: {
    'nodes' => [
      { 'id' => 'n1', 'type' => 'wait', 'config' => { 'duration' => 0, 'unit' => 'minutes' } },
      { 'id' => 'n2', 'type' => 'send_email', 'config' => { 'to' => '{{entity.email}}', 'subject' => '{{params.welcome_subject}}', 'body' => '{{params.welcome_body}}' } },
      { 'id' => 'n3', 'type' => 'wait_for_reply', 'config' => { 'timeout_hours' => 72, 'on_reply_branch' => 'n6', 'on_timeout_branch' => 'n4' } },
      { 'id' => 'n4', 'type' => 'send_email', 'config' => { 'to' => '{{entity.email}}', 'subject' => '{{params.followup_subject}}', 'body' => '{{params.followup_body}}' } },
      { 'id' => 'n5', 'type' => 'wait', 'config' => { 'duration' => 3, 'unit' => 'days' } },
      { 'id' => 'n6', 'type' => 'create_activity', 'config' => { 'activity_type' => 'call', 'subject' => 'Call new lead', 'due_in_hours' => 24, 'assigned_to' => 'owner' } }
    ],
    'edges' => [
      { 'id' => 'e_n1_n2', 'source' => 'n1', 'target' => 'n2' },
      { 'id' => 'e_n2_n3', 'source' => 'n2', 'target' => 'n3' },
      { 'id' => 'e_n3_n4', 'source' => 'n3', 'target' => 'n4' },
      { 'id' => 'e_n4_n5', 'source' => 'n4', 'target' => 'n5' },
      { 'id' => 'e_n5_n6', 'source' => 'n5', 'target' => 'n6' }
    ]
  },
  version: 2,
  parameters: {
    'welcome_subject' => 'Welcome to RenterInsight!',
    'welcome_body' => 'Hi {{entity.first_name}}, thanks for your interest in RenterInsight. We are excited to help you.',
    'followup_subject' => 'Following up',
    'followup_body' => 'Hi {{entity.first_name}}, just checking in to see if you had any questions.',
    'followup_wait_days' => 2,
    'call_wait_days' => 3
  },
  parameter_schema: [
    { 'key' => 'welcome_subject', 'label' => 'Welcome Email Subject', 'type' => 'string', 'required' => true, 'default' => 'Welcome to RenterInsight!' },
    { 'key' => 'welcome_body', 'label' => 'Welcome Email Body', 'type' => 'textarea', 'required' => true, 'default' => 'Hi {{entity.first_name}}, thanks for your interest in RenterInsight.' },
    { 'key' => 'followup_subject', 'label' => 'Follow-up Subject', 'type' => 'string', 'required' => true, 'default' => 'Following up' },
    { 'key' => 'followup_body', 'label' => 'Follow-up Body', 'type' => 'textarea', 'required' => true, 'default' => 'Hi {{entity.first_name}}, just checking in.' },
    { 'key' => 'followup_wait_days', 'label' => 'Days before follow-up', 'type' => 'number', 'required' => true, 'default' => 2 }
  ],
  sort_order: 10
}

# (2) lead_status_to_contacted
templates << {
  key: 'lead_status_to_contacted',
  name: 'Lead Contacted - Confirm Interest',
  category: 'Lead Follow-up',
  entity_type: 'Lead',
  icon: 'PhoneCall',
  description: 'When a lead status changes, create a call task to confirm interest.',
  preview_description: 'Triggered when the lead status changes. Creates a call activity assigned to the lead owner to confirm continued interest.',
  required_integrations: [],
  trigger: { 'event_type' => 'lead.status_changed', 'entity_type_filter' => 'Lead' },
  conditions: [],
  steps: {
    'nodes' => [
      { 'id' => 'n1', 'type' => 'create_activity', 'config' => { 'activity_type' => 'call', 'subject' => '{{params.activity_subject}}', 'due_in_hours' => 4, 'assigned_to' => 'owner' } }
    ],
    'edges' => []
  },
  parameters: {
    'activity_subject' => 'Confirm interest with {{entity.first_name}}'
  },
  parameter_schema: [
    { 'key' => 'activity_subject', 'label' => 'Activity Subject', 'type' => 'string', 'required' => true, 'default' => 'Confirm interest with {{entity.first_name}}' }
  ],
  sort_order: 20
}

# (3) quote_sent_nudge
templates << {
  key: 'quote_sent_nudge',
  name: 'Quote Sent Nudge',
  category: 'Deal Pipeline',
  entity_type: 'Deal',
  icon: 'DollarSign',
  description: 'Nudge prospects after a quote has been sent.',
  preview_description: 'Waits a few days after a deal update, sends a nudge email, then schedules a high-priority follow-up call if still no response.',
  required_integrations: [],
  trigger: { 'event_type' => 'deal.updated', 'entity_type_filter' => 'Deal' },
  conditions: [],
  steps: {
    'nodes' => [
      { 'id' => 'n1', 'type' => 'wait', 'config' => { 'duration' => 3, 'unit' => 'days' } },
      { 'id' => 'n2', 'type' => 'send_email', 'config' => { 'subject' => '{{params.nudge_subject}}', 'body' => '{{params.nudge_body}}' } },
      { 'id' => 'n3', 'type' => 'wait_for_reply', 'config' => { 'timeout_hours' => 48, 'on_reply_branch' => 'n5', 'on_timeout_branch' => 'n4' } },
      { 'id' => 'n4', 'type' => 'create_activity', 'config' => { 'activity_type' => 'call', 'subject' => 'Follow up on quote', 'priority' => 'high', 'assigned_to' => 'owner' } },
      { 'id' => 'n5', 'type' => 'create_activity', 'config' => { 'activity_type' => 'task', 'subject' => 'Review prospect reply', 'priority' => 'high', 'assigned_to' => 'owner' } }
    ],
    'edges' => [
      { 'id' => 'e_n1_n2', 'source' => 'n1', 'target' => 'n2' },
      { 'id' => 'e_n2_n3', 'source' => 'n2', 'target' => 'n3' },
      { 'id' => 'e_n3_n4', 'source' => 'n3', 'target' => 'n4' },
      { 'id' => 'e_n3_n5', 'source' => 'n3', 'target' => 'n5' }
    ]
  },
  version: 2,
  parameters: {
    'nudge_subject' => 'Any questions on your quote?',
    'nudge_body' => 'Hi, wanted to check in and see if you had any questions on the quote we sent.',
    'first_wait_days' => 3,
    'second_wait_days' => 2
  },
  parameter_schema: [
    { 'key' => 'nudge_subject', 'label' => 'Nudge Subject', 'type' => 'string', 'required' => true, 'default' => 'Any questions on your quote?' },
    { 'key' => 'nudge_body', 'label' => 'Nudge Body', 'type' => 'textarea', 'required' => true, 'default' => 'Hi, wanted to check in.' },
    { 'key' => 'first_wait_days', 'label' => 'Days before nudge', 'type' => 'number', 'required' => true, 'default' => 3 },
    { 'key' => 'second_wait_days', 'label' => 'Days before call', 'type' => 'number', 'required' => true, 'default' => 2 }
  ],
  sort_order: 30
}

# (4) invoice_overdue_3_days
templates << {
  key: 'invoice_overdue_3_days',
  name: 'Invoice Overdue Reminder',
  category: 'Finance',
  entity_type: 'Invoice',
  icon: 'AlertCircle',
  description: 'Automated overdue invoice reminder and AR task.',
  preview_description: 'When an invoice goes overdue, sends a reminder email and creates an AR follow-up call task for the finance team.',
  required_integrations: [],
  trigger: { 'event_type' => 'invoice.overdue', 'entity_type_filter' => 'Invoice' },
  conditions: [],
  steps: {
    'nodes' => [
      { 'id' => 'n1', 'type' => 'send_email', 'config' => { 'subject' => '{{params.reminder_subject}}', 'body' => '{{params.reminder_body}}' } },
      { 'id' => 'n2', 'type' => 'create_activity', 'config' => { 'activity_type' => 'call', 'subject' => 'AR follow-up call', 'priority' => 'high', 'assigned_to' => 'owner' } }
    ],
    'edges' => linear_edges(%w[n1 n2])
  },
  parameters: {
    'reminder_subject' => 'Invoice overdue - please review',
    'reminder_body' => 'Your invoice is now overdue. Please contact us to resolve.'
  },
  parameter_schema: [
    { 'key' => 'reminder_subject', 'label' => 'Reminder Subject', 'type' => 'string', 'required' => true, 'default' => 'Invoice overdue - please review' },
    { 'key' => 'reminder_body', 'label' => 'Reminder Body', 'type' => 'textarea', 'required' => true, 'default' => 'Your invoice is now overdue.' }
  ],
  sort_order: 40
}

# (5) service_ticket_submitted_ack
templates << {
  key: 'service_ticket_submitted_ack',
  name: 'Service Ticket Acknowledgment',
  category: 'Service Tickets',
  entity_type: 'ServiceTicket',
  icon: 'Ticket',
  description: 'Send auto-acknowledgment email when a service ticket is submitted.',
  preview_description: 'Immediately emails the customer to confirm their service ticket was received and is being reviewed.',
  required_integrations: [],
  trigger: { 'event_type' => 'service_ticket.created', 'entity_type_filter' => 'ServiceTicket' },
  conditions: [],
  steps: {
    'nodes' => [
      { 'id' => 'n1', 'type' => 'send_email', 'config' => { 'subject' => '{{params.ack_subject}}', 'body' => '{{params.ack_body}}' } }
    ],
    'edges' => []
  },
  parameters: {
    'ack_subject' => 'We received your service request',
    'ack_body' => 'Thanks for submitting your service ticket. Our team will review and respond shortly.'
  },
  parameter_schema: [
    { 'key' => 'ack_subject', 'label' => 'Acknowledgment Subject', 'type' => 'string', 'required' => true, 'default' => 'We received your service request' },
    { 'key' => 'ack_body', 'label' => 'Acknowledgment Body', 'type' => 'textarea', 'required' => true, 'default' => 'Thanks for submitting your service ticket.' }
  ],
  sort_order: 50
}

# (6) service_ticket_unassigned_escalate
templates << {
  key: 'service_ticket_unassigned_escalate',
  name: 'Escalate Unassigned Service Tickets',
  category: 'Service Tickets',
  entity_type: 'ServiceTicket',
  icon: 'AlertTriangle',
  description: 'Escalate service tickets that remain unassigned.',
  preview_description: 'Waits a couple of hours after ticket creation and creates a high-priority task to assign a technician if still unassigned.',
  required_integrations: [],
  trigger: { 'event_type' => 'service_ticket.created', 'entity_type_filter' => 'ServiceTicket' },
  conditions: [],
  steps: {
    'nodes' => [
      { 'id' => 'n1', 'type' => 'wait', 'config' => { 'duration' => 2, 'unit' => 'hours' } },
      { 'id' => 'n2', 'type' => 'create_activity', 'config' => { 'activity_type' => 'task', 'subject' => 'Assign technician', 'priority' => 'high', 'assigned_to' => 'owner' } }
    ],
    'edges' => linear_edges(%w[n1 n2])
  },
  parameters: {
    'wait_hours' => 2
  },
  parameter_schema: [
    { 'key' => 'wait_hours', 'label' => 'Hours before escalation', 'type' => 'number', 'required' => true, 'default' => 2 }
  ],
  sort_order: 60
}

# (7) deal_won_celebrate
templates << {
  key: 'deal_won_celebrate',
  name: 'Deal Won - Celebrate & Onboard',
  category: 'Deal Pipeline',
  entity_type: 'Deal',
  icon: 'Trophy',
  description: 'Celebrate a won deal and kick off onboarding.',
  preview_description: 'Sends a thank-you email to the customer and creates an onboarding kickoff task when a deal is marked as won.',
  required_integrations: [],
  trigger: { 'event_type' => 'deal.updated', 'entity_type_filter' => 'Deal' },
  conditions: [],
  steps: {
    'nodes' => [
      { 'id' => 'n1', 'type' => 'send_email', 'config' => { 'subject' => '{{params.thanks_subject}}', 'body' => '{{params.thanks_body}}' } },
      { 'id' => 'n2', 'type' => 'assign_owner', 'config' => { 'strategy' => 'load_balanced' } },
      { 'id' => 'n3', 'type' => 'create_activity', 'config' => { 'activity_type' => 'task', 'subject' => 'Onboarding kickoff', 'assigned_to' => 'owner' } }
    ],
    'edges' => linear_edges(%w[n1 n2 n3])
  },
  version: 2,
  parameters: {
    'thanks_subject' => 'Welcome aboard!',
    'thanks_body' => 'Thank you for choosing us. We are excited to get started.'
  },
  parameter_schema: [
    { 'key' => 'thanks_subject', 'label' => 'Thank You Subject', 'type' => 'string', 'required' => true, 'default' => 'Welcome aboard!' },
    { 'key' => 'thanks_body', 'label' => 'Thank You Body', 'type' => 'textarea', 'required' => true, 'default' => 'Thank you for choosing us.' }
  ],
  sort_order: 70
}

# (8) deal_lost_learn
templates << {
  key: 'deal_lost_learn',
  name: 'Deal Lost - Postmortem',
  category: 'Deal Pipeline',
  entity_type: 'Deal',
  icon: 'XCircle',
  description: 'Create a postmortem task when a deal is lost.',
  preview_description: 'Creates a postmortem task assigned to the deal owner to capture lessons learned when a deal is marked as lost.',
  required_integrations: [],
  trigger: { 'event_type' => 'deal.updated', 'entity_type_filter' => 'Deal' },
  conditions: [],
  steps: {
    'nodes' => [
      { 'id' => 'n1', 'type' => 'create_activity', 'config' => { 'activity_type' => 'task', 'subject' => '{{params.postmortem_subject}}', 'assigned_to' => 'owner' } }
    ],
    'edges' => []
  },
  parameters: {
    'postmortem_subject' => 'Lost deal postmortem - capture lessons learned'
  },
  parameter_schema: [
    { 'key' => 'postmortem_subject', 'label' => 'Postmortem Subject', 'type' => 'string', 'required' => true, 'default' => 'Lost deal postmortem - capture lessons learned' }
  ],
  sort_order: 80
}

# (9) new_contact_intro
templates << {
  key: 'new_contact_intro',
  name: 'New Contact Introduction',
  category: 'Customer Onboarding',
  entity_type: 'Contact',
  icon: 'Users',
  description: 'Introduce new contacts with an intro email and check-in.',
  preview_description: 'Sends an introduction email when a new contact is created, then a check-in email a week later.',
  required_integrations: [],
  trigger: { 'event_type' => 'contact.created', 'entity_type_filter' => 'Contact' },
  conditions: [],
  steps: {
    'nodes' => [
      { 'id' => 'n1', 'type' => 'send_email', 'config' => { 'subject' => '{{params.intro_subject}}', 'body' => '{{params.intro_body}}' } },
      { 'id' => 'n2', 'type' => 'wait', 'config' => { 'duration' => 7, 'unit' => 'days' } },
      { 'id' => 'n3', 'type' => 'send_email', 'config' => { 'subject' => '{{params.checkin_subject}}', 'body' => '{{params.checkin_body}}' } }
    ],
    'edges' => linear_edges(%w[n1 n2 n3])
  },
  parameters: {
    'intro_subject' => 'Nice to meet you!',
    'intro_body' => 'Thanks for connecting with us. Here is a bit about who we are.',
    'checkin_subject' => 'Checking in',
    'checkin_body' => 'Just wanted to check in and see how things are going.',
    'checkin_wait_days' => 7
  },
  parameter_schema: [
    { 'key' => 'intro_subject', 'label' => 'Intro Subject', 'type' => 'string', 'required' => true, 'default' => 'Nice to meet you!' },
    { 'key' => 'intro_body', 'label' => 'Intro Body', 'type' => 'textarea', 'required' => true, 'default' => 'Thanks for connecting.' },
    { 'key' => 'checkin_subject', 'label' => 'Check-in Subject', 'type' => 'string', 'required' => true, 'default' => 'Checking in' },
    { 'key' => 'checkin_body', 'label' => 'Check-in Body', 'type' => 'textarea', 'required' => true, 'default' => 'Just wanted to check in.' },
    { 'key' => 'checkin_wait_days', 'label' => 'Days before check-in', 'type' => 'number', 'required' => true, 'default' => 7 }
  ],
  sort_order: 90
}

# (10) abandoned_lead_reengage
templates << {
  key: 'abandoned_lead_reengage',
  name: 'Re-engage Stale Lead',
  category: 'Lead Follow-up',
  entity_type: 'Lead',
  icon: 'Clock',
  description: 'Re-engage stale leads with an email and final call.',
  preview_description: 'When a lead goes stale, sends a re-engagement email, waits several days, then creates a final call task.',
  required_integrations: [],
  trigger: { 'event_type' => 'lead.stale', 'entity_type_filter' => 'Lead' },
  conditions: [],
  steps: {
    'nodes' => [
      { 'id' => 'n1', 'type' => 'send_email', 'config' => { 'subject' => '{{params.reengage_subject}}', 'body' => '{{params.reengage_body}}' } },
      { 'id' => 'n2', 'type' => 'wait', 'config' => { 'duration' => 5, 'unit' => 'days' } },
      { 'id' => 'n3', 'type' => 'create_activity', 'config' => { 'activity_type' => 'call', 'subject' => 'Final call attempt', 'assigned_to' => 'owner' } }
    ],
    'edges' => linear_edges(%w[n1 n2 n3])
  },
  version: 2,
  parameters: {
    'reengage_subject' => 'Still interested?',
    'reengage_body' => 'Hi, we noticed we have not heard from you. Still interested in chatting?',
    'final_wait_days' => 5,
    'halt_on_reply' => 'true'
  },
  parameter_schema: [
    { 'key' => 'reengage_subject', 'label' => 'Re-engage Subject', 'type' => 'string', 'required' => true, 'default' => 'Still interested?' },
    { 'key' => 'reengage_body', 'label' => 'Re-engage Body', 'type' => 'textarea', 'required' => true, 'default' => 'Hi, we noticed we have not heard from you.' },
    { 'key' => 'final_wait_days', 'label' => 'Days before final call', 'type' => 'number', 'required' => true, 'default' => 5 }
  ],
  sort_order: 100
}

templates.each do |attrs|
  key = attrs.delete(:key)
  upsert_template(key, attrs.merge(is_active: true))
end

puts "Seeded #{WorkflowTemplate.count} workflow templates"
