class CreateLeadStatuses < ActiveRecord::Migration[8.0]
  # Tenant-configurable lead statuses (parallel to Sources, vs the hardcoded
  # LeadStatus enum on the frontend that bloated `leads.status` over time).
  # Seeded with the legacy enum + every distinct status currently in use per
  # company so existing leads stay valid and tenants like Evangeline keep
  # their imported `open`/`lost`/`working` etc.
  DEFAULT_STATUSES = [
    { key: 'new',                   label: 'New',                   sort_order: 10,  is_excluded: false },
    { key: 'not_contacted',         label: 'Not Contacted',         sort_order: 20,  is_excluded: false },
    { key: 'attempted_to_contact',  label: 'Attempted to Contact',  sort_order: 30,  is_excluded: false },
    { key: 'contact_in_future',     label: 'Contact in Future',     sort_order: 40,  is_excluded: false },
    { key: 'contacted',             label: 'Contacted',             sort_order: 50,  is_excluded: false },
    { key: 'engaged',               label: 'Engaged',               sort_order: 60,  is_excluded: false },
    { key: 'pre_qualified',         label: 'Pre-Qualified',         sort_order: 70,  is_excluded: false },
    { key: 'qualified',             label: 'Qualified',             sort_order: 80,  is_excluded: false },
    { key: 'showing_scheduled',     label: 'Showing Scheduled',     sort_order: 90,  is_excluded: false },
    { key: 'proposal',              label: 'Proposal',              sort_order: 100, is_excluded: false },
    { key: 'negotiation',           label: 'Negotiation',           sort_order: 110, is_excluded: false },
    { key: 'application_submitted', label: 'Application Submitted', sort_order: 120, is_excluded: false },
    { key: 'closed_won',            label: 'Closed Won',            sort_order: 200, is_excluded: false },
    { key: 'closed_lost',           label: 'Closed Lost',           sort_order: 900, is_excluded: true },
    { key: 'lost_lead',             label: 'Lost Lead',             sort_order: 910, is_excluded: true },
    { key: 'not_qualified',         label: 'Not Qualified',         sort_order: 920, is_excluded: true },
    { key: 'junk_lead',             label: 'Junk Lead',             sort_order: 930, is_excluded: true },
  ].freeze

  def up
    create_table :lead_statuses do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.string  :key,        null: false
      t.string  :label,      null: false
      t.string  :color
      t.integer :sort_order, default: 0, null: false
      t.boolean :is_active,  default: true, null: false
      # Dead-end statuses excluded from the "All Active" view (replaces the
      # hardcoded EXCLUDED_STATUSES constant in LeadsController).
      t.boolean :is_excluded, default: false, null: false
      t.timestamps
    end
    add_index :lead_statuses, [:company_id, :key], unique: true
    add_index :lead_statuses, [:company_id, :is_active]

    # Seed every existing company with the defaults + any extra statuses that
    # show up in their leads.status column today.
    seed_existing_companies
  end

  def down
    drop_table :lead_statuses
  end

  private

  # Every row in an insert_all batch must have the same keys. Build a complete
  # hash with all columns explicitly so the defaults block + the per-company
  # extras block produce identically-shaped rows.
  def build_row(company_id, now, key:, label:, sort_order:, is_excluded:, color: nil, is_active: true)
    {
      company_id: company_id,
      key: key,
      label: label,
      color: color,
      sort_order: sort_order,
      is_active: is_active,
      is_excluded: is_excluded,
      created_at: now,
      updated_at: now,
    }
  end

  def seed_existing_companies
    say_with_time 'Seeding lead_statuses for existing companies' do
      now = Time.current
      default_keys = DEFAULT_STATUSES.map { |s| s[:key] }

      Company.find_each do |company|
        rows = DEFAULT_STATUSES.map do |s|
          build_row(company.id, now, **s)
        end

        # Add any extra status strings that already exist on this company's
        # leads but aren't in the defaults — humanize the key for the label.
        extra_keys = company.leads
                            .where.not(status: [nil, ''])
                            .where.not(status: default_keys)
                            .distinct
                            .pluck(:status)
        extra_keys.each_with_index do |key, idx|
          rows << build_row(company.id, now,
                            key: key,
                            label: key.to_s.humanize,
                            sort_order: 500 + idx, # between active and excluded blocks
                            is_excluded: false)
        end

        LeadStatus.insert_all(rows) if rows.any?
      end
    end
  end
end
