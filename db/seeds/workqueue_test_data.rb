# frozen_string_literal: true
#
# Workqueue seed data for dev testing.
# Run with: bin/rails runner db/seeds/workqueue_test_data.rb
#
# Idempotent — checks for existing records with WORKQUEUE_SEED marker.

MARKER = 'WORKQUEUE_SEED'

company = Company.find_by(id: 19) || Company.first
abort("No company found — cannot seed workqueue data") unless company

user = company.users.where(status: 'active').where.not(role: 'platform_admin').first
abort("No active non-platform-admin user found for company #{company.id}") unless user

puts "Seeding workqueue test data for #{user.email} (user #{user.id}) in company #{company.name} (#{company.id})"

# ── Helper ──────────────────────────────────────────────────────────

def already_seeded?(klass, company, marker_field, marker)
  klass.where(company_id: company.id).where("#{marker_field} LIKE ?", "%#{marker}%").exists?
end

# ── Leads ───────────────────────────────────────────────────────────

unless already_seeded?(Lead, company, 'notes', MARKER)
  source = company.sources.first

  leads = [
    { first_name: 'Alice', last_name: 'Workqueue', email: 'alice.wq@example.com',
      status: 'new', created_at: 2.hours.ago, last_activity_at: 1.hour.ago,
      notes: "Fresh lead #{MARKER}" },
    { first_name: 'Bob', last_name: 'Workqueue', email: 'bob.wq@example.com',
      status: 'contacted', created_at: 5.days.ago, last_activity_at: 4.days.ago,
      notes: "Stale lead #{MARKER}" },
    { first_name: 'Carol', last_name: 'Workqueue', email: 'carol.wq@example.com',
      status: 'new', created_at: 12.hours.ago, last_activity_at: nil,
      notes: "New no-activity lead #{MARKER}" },
  ]

  leads.each do |attrs|
    lead = Lead.create!(
      company: company,
      location: company.locations.first,
      owner_id: user.id,
      source: source,
      **attrs
    )
    puts "  Created Lead ##{lead.id}: #{lead.first_name} #{lead.last_name}"
  end
else
  puts "  Leads already seeded — skipping"
end

# ── Deals ───────────────────────────────────────────────────────────

unless company.deals.where(deleted_at: nil).where("notes LIKE ?", "%#{MARKER}%").exists?
  account = company.accounts.where(is_deleted: [false, nil]).first

  deals = [
    { name: 'WQ Deal This Month', deal_number: 'WQ-D001', stage: 'proposal',
      expected_close_date: Date.current.end_of_month, value: 45_000,
      notes: "Closing this month #{MARKER}" },
    { name: 'WQ Deal This Week', deal_number: 'WQ-D002', stage: 'negotiation',
      expected_close_date: 3.days.from_now.to_date, value: 62_000,
      notes: "Closing this week #{MARKER}" },
  ]

  deals.each do |attrs|
    deal = Deal.create!(
      company: company,
      location: company.locations.first,
      user_id: user.id,
      owner_id: user.id,
      account: account,
      source: company.sources.first,
      **attrs
    )
    puts "  Created Deal ##{deal.id}: #{deal.name}"
  end
else
  puts "  Deals already seeded — skipping"
end

# ── Tasks ───────────────────────────────────────────────────────────

unless Task.where(company_id: company.id).where("description LIKE ?", "%#{MARKER}%").exists?
  tasks = [
    { title: 'WQ Follow up with prospect', description: "Overdue task #{MARKER}",
      due_date: 2.days.ago, status: :pending, priority: :high },
    { title: 'WQ Prepare quote package', description: "Due today task #{MARKER}",
      due_date: Date.current.end_of_day, status: :pending, priority: :medium },
  ]

  tasks.each do |attrs|
    task = Task.create!(
      company: company,
      location: company.locations.first,
      assigned_to_id: user.id,
      **attrs
    )
    puts "  Created Task ##{task.id}: #{task.title}"
  end
else
  puts "  Tasks already seeded — skipping"
end

# ── Lead Activity (call due today) ──────────────────────────────────

seed_leads = company.leads.where(owner_id: user.id).where("notes LIKE ?", "%#{MARKER}%")
if seed_leads.any?
  lead = seed_leads.first
  unless LeadActivity.where(lead_id: lead.id).where("subject LIKE ?", "%#{MARKER}%").exists?
    activity = LeadActivity.create!(
      lead: lead,
      user: user,
      assigned_to_id: user.id,
      activity_type: 'call',
      subject: "WQ Follow-up call #{MARKER}",
      status: 'pending',
      priority: 'high',
      due_date: Date.current.end_of_day,
      phone_number: '555-0100',
      call_direction: 'outbound'
    )
    puts "  Created LeadActivity ##{activity.id}: #{activity.subject}"
  else
    puts "  Lead activities already seeded — skipping"
  end
else
  puts "  No seed leads found — skipping lead activity creation"
end

puts "\nWorkqueue seed complete!"
puts "  Company: #{company.id} (#{company.name})"
puts "  User:    #{user.id} (#{user.email})"
puts "  Verify:  bin/rails runner \"pp WorkqueueService.new(company: Company.find(#{company.id}), user: User.find(#{user.id})).summary\""
