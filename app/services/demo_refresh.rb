# frozen_string_literal: true

# Puts a demo company's Workqueue and calendar back to "this morning": buyers
# viewing homes, brochures opened, emails opened and clicked, a reply waiting,
# new web leads, tasks due today, meetings this week, deals closing, quotes
# out and invoices overdue.
#
# Demo data goes stale because every queue is a time window (48 hours, today,
# this week) and seeded rows only age. Rather than sliding every date in the
# company, this keeps a small cast of demo buyers (found by their example.com
# addresses) and rebuilds their signals relative to now, owned by whoever
# pressed the button. A platform admin demoing the account therefore sees the
# same queue a rep would, without picking a user first.
#
# Only the cast and the rows hanging off it are touched; the rest of the
# company is left alone. Whatever was done to the cast during the last demo
# (calls logged, tasks completed, emails sent, rows dismissed) is wiped so the
# next demo starts clean.
#
# Rows are written with insert_all/update_all on purpose: no workflow,
# reminder, nurture or webhook callback fires. A demo refresh must never send
# anything to anyone.
#
# Gated twice: the company must be flagged is_demo AND listed in
# DEMO_REFRESH_COMPANY_IDS, which is set on staging only.
class DemoRefresh
  SETTING_KEY = 'demo_refresh'
  EMAIL_DOMAIN = 'example.com'

  # The demo buyers. Keys name the story each one carries below.
  LEADS = {
    jenna:  { first_name: 'Jenna',  last_name: 'Ortiz',   city: 'Littleton',     status: 'engaged',   budget_range: '$150k - $200k', purchase_timeframe: '0-3 months' },
    marcus: { first_name: 'Marcus', last_name: 'Bell',    city: 'Aurora',        status: 'contacted', budget_range: '$100k - $150k', purchase_timeframe: '3-6 months' },
    priya:  { first_name: 'Priya',  last_name: 'Nair',    city: 'Lakewood',      status: 'engaged',   budget_range: '$200k+',        purchase_timeframe: '0-3 months' },
    caleb:  { first_name: 'Caleb',  last_name: 'Turner',  city: 'Brighton',      status: 'contacted', budget_range: '$100k - $150k', purchase_timeframe: '3-6 months' },
    rosa:   { first_name: 'Rosa',   last_name: 'Delgado', city: 'Commerce City', status: 'new', origin: Lead::ORIGIN_INTAKE_FORM, budget_range: '$100k - $150k', purchase_timeframe: '0-3 months' },
    tyler:  { first_name: 'Tyler',  last_name: 'Brooks',  city: 'Thornton',      status: 'new', origin: Lead::ORIGIN_FACEBOOK,    budget_range: '$150k - $200k', purchase_timeframe: '3-6 months' },
    hannah: { first_name: 'Hannah', last_name: 'Kim',     city: 'Englewood',     status: 'engaged',   budget_range: '$150k - $200k', purchase_timeframe: '0-3 months' },
    derek:  { first_name: 'Derek',  last_name: 'Watts',   city: 'Golden',        status: 'contacted', budget_range: '$100k - $150k', purchase_timeframe: '0-3 months' },
    megan:  { first_name: 'Megan',  last_name: 'Shaw',    city: 'Arvada',        status: 'contacted', budget_range: '$100k - $150k', purchase_timeframe: '6-12 months' },
    luis:   { first_name: 'Luis',   last_name: 'Romero',  city: 'Westminster',   status: 'contacted', budget_range: '$150k - $200k', purchase_timeframe: '3-6 months' },
    ashley: { first_name: 'Ashley', last_name: 'Grant',   city: 'Parker',        status: 'engaged',   budget_range: '$200k+',        purchase_timeframe: '0-3 months' },
  }.freeze

  CONTACTS = {
    robert:   { first_name: 'Robert',   last_name: 'Hayes',  city: 'Castle Rock' },
    lisa:     { first_name: 'Lisa',     last_name: 'Moreno', city: 'Centennial' },
    kevin:    { first_name: 'Kevin',    last_name: 'Novak',  city: 'Brighton' },
    samantha: { first_name: 'Samantha', last_name: 'Reyes',  city: 'Erie' },
    greg:     { first_name: 'Greg',     last_name: 'Patel',  city: 'Longmont' },
  }.freeze

  class NotAvailable < StandardError; end

  def self.company_ids
    ENV.fetch('DEMO_REFRESH_COMPANY_IDS', '').split(',').map(&:strip).reject(&:blank?).map(&:to_i)
  end

  def self.available?(company)
    company.present? && company.is_demo? && company_ids.include?(company.id)
  end

  # The user the last refresh was run for, so the nightly job can keep that
  # person's queue warm.
  def self.last_user_id(company)
    state = Setting.get('Company', company.id, SETTING_KEY, {})
    state.is_a?(Hash) ? state['user_id'] : nil
  end

  def self.email_for(first_name, last_name)
    "#{first_name}.#{last_name}@#{EMAIL_DOMAIN}".downcase
  end

  def initialize(company:, user:)
    @company = company
    @user = user
  end

  def call
    raise NotAvailable, 'Demo refresh is not turned on for this company.' unless self.class.available?(@company)

    @now = Time.current
    @counts = Hash.new(0)

    ActiveRecord::Base.transaction do
      leads = upsert_cast(@company.leads, LEADS) { |attrs| lead_row(attrs) }
      contacts = upsert_cast(@company.contacts, CONTACTS) { |attrs| contact_row(attrs) }
      @leads = leads
      @contacts = contacts

      clear_signals
      reset_leads
      reset_contacts

      build_inventory_interest
      build_brochure_views
      build_campaign_engagement
      build_landing_visits
      build_replies
      build_design
      build_activities
      build_deals
      build_quotes
      build_invoices
    end

    Setting.set('Company', @company.id, SETTING_KEY,
                { 'user_id' => @user.id, 'refreshed_at' => @now.iso8601 })

    { refreshed_at: @now, user_id: @user.id, created: @counts }
  end

  private

  # ─── Cast ──────────────────────────────────────────────────────────

  # { key => id }, inserting any cast member that is missing (first run, or
  # deleted during a demo). Matched by email so no id has to be remembered.
  def upsert_cast(scope, cast)
    emails = cast.transform_values { |a| self.class.email_for(a[:first_name], a[:last_name]) }
    existing = scope.where(email: emails.values).pluck(:email, :id).to_h { |e, id| [e.downcase, id] }

    missing = cast.reject { |key, _| existing.key?(emails[key]) }
    if missing.any?
      rows = missing.map { |_, attrs| yield(attrs) }
      scope.klass.insert_all!(rows)
      existing = scope.where(email: emails.values).pluck(:email, :id).to_h { |e, id| [e.downcase, id] }
    end

    emails.transform_values { |email| existing.fetch(email) }
  end

  def lead_row(attrs)
    {
      company_id: @company.id,
      first_name: attrs[:first_name], last_name: attrs[:last_name],
      email: self.class.email_for(attrs[:first_name], attrs[:last_name]),
      phone: fake_phone(attrs[:first_name]),
      city: attrs[:city], state: 'CO', status: 'new',
      created_at: @now, updated_at: @now,
    }
  end

  def contact_row(attrs)
    {
      company_id: @company.id,
      first_name: attrs[:first_name], last_name: attrs[:last_name],
      email: self.class.email_for(attrs[:first_name], attrs[:last_name]),
      phone: fake_phone(attrs[:first_name]),
      city: attrs[:city], state: 'CO',
      created_at: @now, updated_at: @now,
    }
  end

  # 555-01xx is reserved for fiction, so nothing can ever text a real phone.
  def fake_phone(seed)
    "(303) 555-01#{format('%02d', seed.sum % 100)}"
  end

  # How long ago each lead came in, and when they last did anything.
  LEAD_TIMING = {
    jenna:  { created: 12.days, active: 1.hour },
    marcus: { created: 9.days,  active: 3.hours },
    priya:  { created: 6.days,  active: 35.minutes },
    caleb:  { created: 15.days, active: 5.hours },
    rosa:   { created: 25.minutes, active: 25.minutes },
    tyler:  { created: 2.hours, active: 2.hours },
    hannah: { created: 8.days,  active: 30.minutes },
    derek:  { created: 10.days, active: 50.minutes },
    megan:  { created: 20.days, active: 3.hours },
    luis:   { created: 24.days, active: 5.days },
    ashley: { created: 4.days,  active: 2.hours },
  }.freeze

  def reset_leads
    known = @company.lead_statuses.pluck(:key)
    LEADS.each do |key, attrs|
      timing = LEAD_TIMING.fetch(key)
      status = known.empty? || known.include?(attrs[:status]) ? attrs[:status] : 'new'
      @company.leads.where(id: @leads[key]).update_all(
        owner_id: @user.id, location_id: location_id, status: status,
        origin: attrs[:origin], is_converted: false, converted_at: nil,
        converted_account_id: nil, merged_into_id: nil, merged_at: nil, merged_by_id: nil,
        vehicle_id: vehicles[LEADS.keys.index(key) % [vehicles.size, 1].max]&.id,
        budget_range: attrs[:budget_range], purchase_timeframe: attrs[:purchase_timeframe],
        preferred_contact_method: 'phone', email_invalid: false,
        created_at: @now - timing[:created], source_created_at: @now - timing[:created],
        last_activity_at: @now - timing[:active], updated_at: @now
      )
    end
  end

  def reset_contacts
    @company.contacts.where(id: @contacts.values).update_all(
      owner_id: @user.id, location_id: location_id, is_deleted: false,
      merged_into_id: nil, email_invalid: false, opt_out_email: false, opt_out_sms: false,
      updated_at: @now
    )
  end

  # Everything the last refresh built, plus whatever the last demo added to
  # the cast, so the next one starts clean.
  def clear_signals
    lead_ids = @leads.values
    contact_ids = @contacts.values

    comm_ids = Communication.where(communicable_type: 'Lead', communicable_id: lead_ids)
                            .or(Communication.where(communicable_type: 'Contact', communicable_id: contact_ids))
                            .pluck(:id)

    link_ids = TrackedLink.where(company_id: @company.id)
                          .where(entity_type: 'Lead', entity_id: lead_ids)
                          .or(TrackedLink.where(company_id: @company.id, entity_type: 'Contact', entity_id: contact_ids))
                          .or(TrackedLink.where(communication_id: comm_ids))
                          .pluck(:id)
    TrackedLinkEvent.where(tracked_link_id: link_ids).delete_all
    TrackedLink.where(id: link_ids).delete_all

    thread_ids = Communication.where(id: comm_ids).distinct.pluck(:communication_thread_id).compact
    CommunicationEvent.where(communication_id: comm_ids).delete_all
    Communication.where(id: comm_ids).delete_all
    # Threads are found through their messages, so each refresh opens new
    # ones. Drop the old ones once they are empty.
    CommunicationThread.where(id: thread_ids)
                       .where.not(id: Communication.where(communication_thread_id: thread_ids).select(:communication_thread_id))
                       .delete_all

    enrollments = CampaignEnrollment.where(company_id: @company.id, recipient_type: 'Lead', recipient_id: lead_ids)
    CampaignSend.where(campaign_enrollment_id: enrollments.select(:id)).delete_all
    enrollments.delete_all

    visits = PageVisit.where(company_id: @company.id, identified_entity_type: 'Lead', identified_entity_id: lead_ids)
    PageVisitEvent.where(page_visit_id: visits.select(:id)).delete_all
    visits.delete_all

    LeadActivity.where(lead_id: lead_ids).delete_all
    ContactActivity.where(contact_id: contact_ids).delete_all
    @company.truebuild_designs.where(lead_id: lead_ids).delete_all

    # Rows set aside in the last demo would otherwise stay hidden.
    WorkqueueDismissal.where(company_id: @company.id, user_id: @user.id).delete_all
  end

  # ─── Signals ───────────────────────────────────────────────────────

  # Hot Inventory Interest: two or more views of one home in 48 hours.
  def build_inventory_interest
    return if vehicles.empty?

    rows = [[:jenna, 0, 5, 1.hour], [:marcus, 1, 3, 3.hours], [:ashley, 2, 2, 6.hours]].map do |key, vi, clicks, ago|
      tracked_link_row(entity: ['Lead', @leads[key]], vehicle: vehicles[vi % vehicles.size],
                       link_type: 'inventory_view', clicks: clicks, last: @now - ago)
    end
    insert(TrackedLink, rows, :inventory_views)
  end

  # Brochure Hot Interest: a collection opened, and a home inside it clicked.
  def build_brochure_views
    return unless brochure

    rows = [
      tracked_link_row(entity: ['Lead', @leads[:priya]], source: brochure, link_type: 'brochure_view',
                       clicks: 2, last: @now - 40.minutes),
      tracked_link_row(entity: ['Lead', @leads[:caleb]], source: brochure, link_type: 'brochure_view',
                       clicks: 1, last: @now - 5.hours),
    ]
    if vehicles.any?
      rows << tracked_link_row(entity: ['Lead', @leads[:priya]], source: brochure, vehicle: vehicles[3 % vehicles.size],
                               link_type: 'brochure_listing', clicks: 3, last: @now - 35.minutes)
    end
    insert(TrackedLink, rows, :brochure_views)
  end

  # Opened today, clicked today, opened three times or more, opened this week.
  def build_campaign_engagement
    step = campaign_step
    return unless step

    plan = {
      jenna:  { sent: 1.day,  opened: 2.hours,  opens: 1 },
      marcus: { sent: 1.day,  opened: 4.hours,  opens: 2, clicked: 3.hours, clicks: 2 },
      hannah: { sent: 2.days, opened: 30.minutes, opens: 4, clicked: 1.day, clicks: 1 },
      caleb:  { sent: 1.day,  opened: 20.hours, opens: 1 },
      megan:  { sent: 4.days, opened: 3.days,   opens: 1 },
    }

    enrollment_rows = plan.map do |key, p|
      {
        company_id: @company.id, campaign_id: step.campaign_id,
        recipient_type: 'Lead', recipient_id: @leads[key],
        email_address_snapshot: lead_email(key),
        # Finished, so the campaign runner never picks it up and sends.
        status: 'completed', current_step_index: 1,
        last_sent_at: @now - p[:sent], metadata: { 'demo_refresh' => true },
        created_at: @now - p[:sent], updated_at: @now,
      }
    end
    CampaignEnrollment.insert_all!(enrollment_rows)
    enrollment_ids = CampaignEnrollment.where(campaign_id: step.campaign_id, recipient_type: 'Lead',
                                              recipient_id: @leads.values_at(*plan.keys))
                                       .pluck(:recipient_id, :id).to_h

    send_rows = plan.map do |key, p|
      {
        company_id: @company.id, campaign_id: step.campaign_id, campaign_step_id: step.id,
        campaign_enrollment_id: enrollment_ids.fetch(@leads[key]),
        sent_at: @now - p[:sent], delivered_at: @now - p[:sent],
        opened_at: @now - p[:opened], open_count: p[:opens],
        clicked_at: p[:clicked] && (@now - p[:clicked]), click_count: p[:clicks] || 0,
        metadata: { 'demo_refresh' => true },
        created_at: @now - p[:sent], updated_at: @now,
      }
    end
    insert(CampaignSend, send_rows, :email_opens)
  end

  # Visited a landing page today; one read to the bottom and did not convert.
  def build_landing_visits
    return unless website_page

    rows = [
      visit_row(:hannah, ago: 45.minutes, scroll: 92, duration: 4.minutes),
      visit_row(:megan, ago: 3.hours, scroll: 30, duration: 40.seconds),
    ]
    insert(PageVisit, rows, :landing_visits)
  end

  # Replied and waiting on us: one lead by email, one customer by text. Plus a
  # customer who opened and clicked a direct email today.
  def build_replies
    email_from = @user.email

    comms = [
      comm_row('Lead', @leads[:derek], direction: 'outbound', channel: 'email', at: @now - 1.day,
               from: email_from, to: lead_email(:derek),
               subject: 'Lot options near Golden',
               body: "Hi Derek, I pulled three lots that fit the 28x60 you liked. Want me to send the site plans?"),
      comm_row('Lead', @leads[:derek], direction: 'inbound', channel: 'email', at: @now - 50.minutes,
               from: lead_email(:derek), to: email_from,
               subject: 'Re: Lot options near Golden',
               body: "Yes please. The second lot looks great. Can we walk it this weekend?"),
      comm_row('Contact', @contacts[:robert], direction: 'outbound', channel: 'sms', at: @now - 1.day,
               from: nil, to: fake_phone('Robert'),
               body: "Hi Robert, your home is on the lot and ready for a final walkthrough."),
      comm_row('Contact', @contacts[:robert], direction: 'inbound', channel: 'sms', at: @now - 1.hour,
               from: fake_phone('Robert'), to: nil,
               body: "Great news. Could we come by Saturday morning with my wife?"),
      comm_row('Contact', @contacts[:lisa], direction: 'outbound', channel: 'email', at: @now - 3.hours,
               from: email_from, to: contact_email(:lisa),
               subject: 'Your service visit is booked',
               body: "Hi Lisa, here are the details for your skirting repair and a link to our winter maintenance checklist."),
    ]
    inserted = Communication.insert_all!(comms, returning: %w[id communicable_type communicable_id direction])
    @counts[:messages] += inserted.length

    lisa_comm = inserted.rows.find { |_, type, id, _| type == 'Contact' && id == @contacts[:lisa] }&.first
    return unless lisa_comm

    events = [
      { communication_id: lisa_comm, event_type: 'opened',  occurred_at: @now - 1.hour,     created_at: @now, updated_at: @now },
      { communication_id: lisa_comm, event_type: 'clicked', occurred_at: @now - 50.minutes, created_at: @now, updated_at: @now },
    ]
    insert(CommunicationEvent, events, :message_events)
  end

  # Designed a home on the website, opened it again today, shared it with family.
  # Copies the plan and options from one of the company's real saved designs.
  def build_design
    template = @company.truebuild_designs.where.not(lead_id: @leads.values).order(:id).first
    return unless template

    row = {
      company_id: @company.id,
      catalog_plan_variant_id: template.catalog_plan_variant_id,
      catalog_price_book_id: template.catalog_price_book_id,
      vehicle_id: template.vehicle_id,
      lead_id: @leads[:ashley],
      public_token: SecureRandom.urlsafe_base64(16),
      name: template.name, status: 'saved',
      option_ids: template.option_ids, price_snapshot: template.price_snapshot,
      buyer_email: lead_email(:ashley), buyer_name: 'Ashley Grant',
      view_count: 4, last_viewed_at: @now - 2.hours, share_count: 1,
      metadata: { 'last_shared_at' => (@now - 1.day).iso8601, 'demo_refresh' => true },
      created_at: @now - 1.day, updated_at: @now,
    }
    insert(TruebuildDesign, [row], :designs)
  end

  # Tasks, calls, meetings and a reminder. These are what the calendar shows too.
  def build_activities
    a = []
    a << activity(:priya,  'task', 'Follow up on the brochure she opened', due: @now - 2.hours, priority: 'high')
    a << activity(:caleb,  'task', 'Send floor plan options for a 3 bed', due: later_today(3.hours), priority: 'high')
    a << activity(:jenna,  'task', 'Confirm financing pre-approval', due: later_today(5.hours))
    a << activity(:marcus, 'task', 'Price out a 28x56 with upgraded kitchen', due: on_day(2, 10))
    a << activity(:megan,  'task', 'Send trade-in estimate', due: on_day(4, 11), priority: 'low')
    a << activity(:hannah, 'task', 'Ask about lot and land situation', due: on_day(6, 9))
    a << activity(:luis,   'call', 'Check in, no reply in 5 days', due: @now - 1.day, priority: 'high')
    a << activity(:rosa,   'call', 'Welcome call for new web lead', due: later_today(1.hour), priority: 'urgent')
    a << activity(:derek,  'task', 'Reply to Derek about walking the lot', due: later_today(1.hour),
                  reminder: @now + 45.minutes, priority: 'high')

    tour = later_today(2.hours)
    a << activity(:jenna,  'meeting', 'Model home tour', due: tour, start: tour, minutes: 60,
                  where: location_name)
    a << activity(:marcus, 'meeting', 'Walk the lot and review financing', due: on_day(1, 10), start: on_day(1, 10),
                  minutes: 60, where: location_name)
    a << activity(:ashley, 'meeting', 'Design review for her saved home', due: on_day(3, 14), start: on_day(3, 14),
                  minutes: 45, where: 'Video call')

    insert(LeadActivity, a, :activities)
  end

  # ─── Deals, quotes, invoices ───────────────────────────────────────
  #
  # Kept and reset rather than rebuilt, so deal and invoice numbers stay put
  # instead of climbing on every refresh. Found by their cast contact.

  # Closing this week, closing this month, and one gone quiet for a month.
  def build_deals
    today = @now.to_date
    plan = {
      kevin:    { stage: open_stage('negotiation', 'proposal'), close: today + 3, active: 1.day, created: 21.days, vi: 4 },
      samantha: { stage: open_stage('proposal', 'qualified', 'negotiation'), close: [today + 14, today.end_of_month].min,
                  active: 2.days, created: 12.days, vi: 5 },
      greg:     { stage: open_stage('qualified', 'qualification', 'proposal'), close: today + 25, active: 34.days,
                  created: 60.days, vi: 2 },
    }

    @deals = plan.to_h do |key, p|
      contact = CONTACTS[key]
      vehicle = vehicles.any? ? vehicles[p[:vi] % vehicles.size] : nil
      price = home_price(vehicle)
      attrs = {
        name: "#{contact[:last_name]}, #{contact[:first_name]}", customer_name: "#{contact[:first_name]} #{contact[:last_name]}",
        stage: p[:stage], expected_close_date: p[:close], actual_close_date: nil, won_at: nil, lost_at: nil, deleted_at: nil,
        user_id: @user.id, owner_id: @user.id, primary_salesperson_id: @user.id, location_id: location_id,
        vehicle_id: vehicle&.id, selling_price: price, total_amount: price, unpaid_balance: price,
        last_activity_at: @now - p[:active], created_at: @now - p[:created], updated_at: @now,
      }
      [key, keep_record(@company.deals, { contact_id: @contacts[key] }, attrs,
                        -> { { deal_number: Deal.new(company_id: @company.id).tap { _1.send(:generate_deal_number) }.deal_number } })]
    end
    DealActivity.where(deal_id: @deals.values).delete_all
    @counts[:deals] += @deals.size
  end

  # Sent and waiting on the buyer.
  def build_quotes
    { kevin: 2.days, samantha: 4.days }.each do |key, sent_ago|
      deal = @company.deals.find(@deals[key])
      vehicle = deal.vehicle_id && vehicles.find { _1.id == deal.vehicle_id }
      price = deal.selling_price.to_f
      items = [
        { 'id' => "demo#{key}home", 'description' => vehicle ? home_name(vehicle) : 'New home', 'quantity' => 1,
          'unit_price' => price.to_s, 'total' => price, 'discount' => 0, 'discount_type' => 'percentage',
          'category' => 'home', 'taxable' => true, 'notes' => '', 'position' => 0 },
        { 'id' => "demo#{key}setup", 'description' => 'Delivery and setup', 'quantity' => 1,
          'unit_price' => '6500.0', 'total' => 6500, 'discount' => 0, 'discount_type' => 'percentage',
          'category' => 'other', 'taxable' => false, 'notes' => '', 'position' => 1 },
      ]
      tax = (price * 0.029).round(2)
      attrs = {
        status: 'sent', sent_at: @now - sent_ago, last_sent_at: @now - sent_ago, viewed_at: nil,
        accepted_at: nil, rejected_at: nil, valid_until: (@now + 12.days).to_date, is_deleted: false, deleted_at: nil,
        sales_rep_id: @user.id, location_id: location_id, vehicle_id: vehicle&.id&.to_s, items: items,
        subtotal: price + 6500, tax: tax, total: price + 6500 + tax,
        created_at: @now - sent_ago - 1.day, updated_at: @now,
      }
      keep_record(@company.quotes, { contact_id: @contacts[key], deal_id: @deals[key] }, attrs,
                  -> { { quote_number: "QUO-#{@now.year}-#{SecureRandom.hex(4).upcase}",
                         public_token: SecureRandom.urlsafe_base64(32) } })
      @counts[:quotes] += 1
    end
  end

  # Past due and unpaid. Marked overdue already, so the overdue reminder email
  # (which picks up sent and viewed invoices) never mails the fictional buyer.
  def build_invoices
    plan = {
      robert: { item: 'Deposit balance for home order', amount: 5000, due: 6.days, issued: 36.days },
      lisa:   { item: 'Skirting repair and winterizing', amount: 485, due: 12.days, issued: 26.days },
    }
    plan.each do |key, p|
      attrs = {
        status: 'overdue', invoice_date: (@now - p[:issued]).to_date, due_date: (@now - p[:due]).to_date,
        subtotal: p[:amount], tax_amount: 0, total: p[:amount], amount_paid: 0, amount_credited: 0,
        amount_due: p[:amount], sent_at: @now - p[:issued], viewed_at: nil, paid_at: nil, is_deleted: false,
        sales_rep_id: @user.id, location_id: location_id,
        created_at: @now - p[:issued], updated_at: @now,
      }
      id = keep_record(@company.invoices, { contact_id: @contacts[key] }, attrs,
                       -> { { invoice_number: Invoice.new(company: @company).tap { _1.send(:generate_invoice_number) }.invoice_number,
                              payment_token: SecureRandom.urlsafe_base64(32), public_token: SecureRandom.urlsafe_base64(32) } })
      InvoiceItem.where(invoice_id: id).delete_all
      InvoiceItem.insert_all!([{ invoice_id: id, description: p[:item], quantity: 1, rate: p[:amount], amount: p[:amount],
                                 position: 0, created_at: @now, updated_at: @now }])
      @counts[:invoices] += 1
    end
  end

  # Updates the record matching `finder`, or inserts it with the extra
  # one-time attributes (numbers, tokens) when it does not exist yet.
  def keep_record(scope, finder, attrs, on_create)
    id = scope.where(finder).order(:id).pick(:id)
    if id
      scope.where(id: id).update_all(attrs)
      id
    else
      row = { company_id: @company.id }.merge(finder, attrs, on_create.call)
      scope.klass.insert_all!([row], returning: %w[id]).rows.first.first
    end
  end

  # An open stage from this dealer's own pipeline, preferring the named ones.
  def open_stage(*preferred)
    open = @company.pipeline_stage_keys - @company.closed_deal_stage_keys
    preferred.find { open.include?(_1) } || open.first || @company.default_deal_stage
  end

  def home_price(vehicle)
    price = vehicle && %i[sale_price price msrp].filter_map { vehicle.try(_1) }.map(&:to_f).find(&:positive?)
    price || 129_900
  end

  def home_name(vehicle)
    [vehicle.year, vehicle.make, vehicle.model].compact.join(' ')
  end

  # ─── Row builders ──────────────────────────────────────────────────

  def tracked_link_row(entity:, link_type:, clicks:, last:, vehicle: nil, source: nil)
    {
      company_id: @company.id, token: SecureRandom.urlsafe_base64(16),
      entity_type: entity[0], entity_id: entity[1],
      source_type: source&.class&.name, source_id: source&.id,
      vehicle_id: vehicle&.id, link_type: link_type,
      click_count: clicks, first_clicked_at: last - 1.day, last_clicked_at: last,
      created_at: last - 1.day, updated_at: @now,
    }
  end

  def visit_row(key, ago:, scroll:, duration:)
    seen = @now - ago
    {
      company_id: @company.id, website_page_id: website_page.id,
      visitor_token: SecureRandom.hex(16), session_token: SecureRandom.hex(16),
      identified_entity_type: 'Lead', identified_entity_id: @leads[key], identified_at: seen - duration,
      device_type: 'mobile', first_seen_at: seen - duration, last_seen_at: seen,
      duration_ms: (duration * 1000).to_i, max_scroll_depth: scroll,
      converted: false, is_bot: false, created_at: seen - duration, updated_at: @now,
    }
  end

  def comm_row(type, id, direction:, channel:, at:, from:, to:, body:, subject: nil)
    {
      company_id: @company.id, communicable_type: type, communicable_id: id,
      communication_thread_id: CommunicationThread.find_or_create_for(
        communicable_type: type, communicable_id: id, channel: channel
      ).id,
      direction: direction, channel: channel, status: 'delivered',
      subject: subject, body: body, from_address: from, to_address: to,
      sent_at: at, delivered_at: (at if direction == 'outbound'), received_at: (at if direction == 'inbound'),
      metadata: comm_metadata(direction == 'outbound' ? { 'sender_user_id' => @user.id, 'demo_refresh' => true } : { 'demo_refresh' => true }),
      created_at: at, updated_at: at,
    }
  end

  # jsonb on the deployed databases, text in db/schema.rb (see
  # Communication.metadata_category_sql). insert_all skips the model, so encode
  # for whichever this database has.
  def comm_metadata(hash)
    Communication.columns_hash['metadata']&.type == :jsonb ? hash : hash.to_json
  end

  def activity(key, type, subject, due:, priority: 'medium', start: nil, minutes: nil, where: nil, reminder: nil)
    {
      lead_id: @leads[key], user_id: @user.id, assigned_to_id: @user.id,
      activity_type: type, subject: subject, status: 'pending', priority: priority,
      due_date: due, start_time: start, end_time: start && minutes && start + minutes.minutes,
      duration_minutes: minutes, meeting_location: where,
      call_direction: ('outbound' if type == 'call'), phone_number: (lead_phone(key) if type == 'call'),
      reminder_time: reminder, reminder_method: ('popup' if reminder),
      # Never invite or remind the (fictional) buyer.
      remind_customer: false, send_calendar_invite: false,
      metadata: { 'demo_refresh' => true },
      created_at: @now - 1.day, updated_at: @now - 1.day,
    }
  end

  def insert(klass, rows, label)
    return if rows.empty?

    klass.insert_all!(rows)
    @counts[label] += rows.size
  end

  # ─── Lookups ───────────────────────────────────────────────────────

  # Still today in the server's day, which is the day the queues use, even
  # when the demo runs late in the evening.
  def later_today(offset)
    [[@now + offset, @now.end_of_day - 10.minutes].min, @now + 5.minutes].max
  end

  # A wall-clock hour on a coming day in the dealer's own time zone, so the
  # calendar reads 10:00 rather than 4:00.
  def on_day(days_ahead, hour)
    zone = ActiveSupport::TimeZone[@company.time_zone] || Time.zone
    date = @now.in_time_zone(zone).to_date + days_ahead
    zone.local(date.year, date.month, date.day, hour)
  end

  def location_id
    @location_id ||= @company.locations.order(:id).pick(:id)
  end

  def location_name
    @location_name ||= @company.locations.order(:id).pick(:name)
  end

  def vehicles
    @vehicles ||= begin
      scope = @company.vehicles.where.not(make: [nil, ''])
      available = scope.where(status: 'available').order(:id).limit(6).to_a
      available.presence || scope.order(:id).limit(6).to_a
    end
  end

  def brochure
    return @brochure if defined?(@brochure)

    @brochure = @company.brochures.where(status: 'active').order(:id).first || @company.brochures.order(:id).first
  end

  # A finished campaign, so no live send ever reaches a demo buyer. Buyer
  # facing campaigns first; the cold-outreach ones are aimed at dealers.
  def campaign_step
    CampaignStep.joins(:campaign)
                .where(channel: 'email', campaigns: { company_id: @company.id, status: %w[completed archived] })
                .order(Arel.sql("CASE WHEN campaigns.name ~* '(inventory|favorites|digest)' THEN 0 ELSE 1 END"),
                       'campaigns.id DESC', 'campaign_steps.position')
                .first
  end

  def website_page
    return @website_page if defined?(@website_page)

    @website_page = WebsitePage.joins(:website)
                               .where(websites: { company_id: @company.id }, is_deleted: false)
                               .order(:id).first
  end

  def lead_email(key)
    self.class.email_for(LEADS[key][:first_name], LEADS[key][:last_name])
  end

  def lead_phone(key)
    fake_phone(LEADS[key][:first_name])
  end

  def contact_email(key)
    self.class.email_for(CONTACTS[key][:first_name], CONTACTS[key][:last_name])
  end
end
