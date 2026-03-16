# Seed default project templates for manufactured housing
# Run with: bin/rails runner "load 'db/seeds/project_templates.rb'"
# Or call ProjectTemplate.seed_defaults!(company) for a specific company

class ProjectTemplate
  def self.seed_defaults!(company)
    Rails.logger.info "[ProjectTemplate] Seeding default templates for Company #{company.id} (#{company.name})"

    # =====================================================================
    # STANDARD MANUFACTURED HOME — Full Lifecycle (Land + Home Package)
    # =====================================================================
    standard = company.project_templates.find_or_create_by!(name: 'Standard Manufactured Home') do |t|
      t.description = 'Full lifecycle for a new manufactured home purchase with land prep, delivery, and installation'
      t.template_type = 'land_home'
      t.is_default = true
      t.is_active = true
      t.created_by_id = company.users.first&.id
    end

    standard_phases = [
      { name: 'Finance Application',       position: 0,  estimated_days: 14, visible_to_client: true,  is_required: true,  notify_client_on_start: false, notify_client_on_complete: true,  icon: 'Landmark',      color: '#6366f1', description: 'Loan application submitted and under review' },
      { name: 'Purchase Agreement Signed',  position: 1,  estimated_days: 7,  visible_to_client: true,  is_required: true,  notify_client_on_start: false, notify_client_on_complete: true,  icon: 'FileSignature', color: '#8b5cf6', description: 'Purchase agreement executed by all parties' },
      { name: 'Home Ordered / In Production', position: 2, estimated_days: 60, visible_to_client: true,  is_required: true,  notify_client_on_start: true,  notify_client_on_complete: true,  icon: 'Factory',       color: '#a855f7', description: 'Home ordered from manufacturer and in production' },
      { name: 'Home Arrives at Dealer',     position: 3,  estimated_days: 14, visible_to_client: true,  is_required: true,  notify_client_on_start: false, notify_client_on_complete: true,  icon: 'Truck',         color: '#3b82f6', description: 'Home delivered to dealer lot for inspection' },
      { name: 'Receiving Inspection (PDI)', position: 4,  estimated_days: 3,  visible_to_client: false, is_required: true,  notify_client_on_start: false, notify_client_on_complete: false, icon: 'ClipboardCheck', color: '#0ea5e9', description: 'Pre-delivery inspection and quality check' },
      { name: 'Land Prep & Permits',        position: 5,  estimated_days: 30, visible_to_client: true,  is_required: true,  notify_client_on_start: true,  notify_client_on_complete: true,  icon: 'Shovel',        color: '#14b8a6', description: 'Foundation, utilities, and building permits' },
      { name: 'Home Delivered to Site',     position: 6,  estimated_days: 7,  visible_to_client: true,  is_required: true,  notify_client_on_start: true,  notify_client_on_complete: true,  icon: 'MapPin',        color: '#22c55e', description: 'Home transported and placed on foundation' },
      { name: 'Installation & Set',         position: 7,  estimated_days: 14, visible_to_client: true,  is_required: true,  notify_client_on_start: true,  notify_client_on_complete: true,  icon: 'Wrench',        color: '#84cc16', description: 'Leveling, blocking, skirting, and exterior finish' },
      { name: 'Utility Connections',        position: 8,  estimated_days: 10, visible_to_client: true,  is_required: true,  notify_client_on_start: false, notify_client_on_complete: true,  icon: 'Zap',           color: '#eab308', description: 'Electrical, plumbing, HVAC, water, sewer hookups' },
      { name: 'Interior Finish',            position: 9,  estimated_days: 14, visible_to_client: true,  is_required: true,  notify_client_on_start: false, notify_client_on_complete: true,  icon: 'PaintBucket',   color: '#f97316', description: 'Drywall marriage line, trim, carpet, appliances' },
      { name: 'Final Inspection',           position: 10, estimated_days: 7,  visible_to_client: true,  is_required: true,  notify_client_on_start: false, notify_client_on_complete: true,  icon: 'ShieldCheck',   color: '#ef4444', description: 'County or state building inspector sign-off' },
      { name: 'Punch List & Walk-Through',  position: 11, estimated_days: 7,  visible_to_client: true,  is_required: true,  notify_client_on_start: true,  notify_client_on_complete: true,  icon: 'ListChecks',    color: '#ec4899', description: 'Buyer walk-through and punch list items' },
      { name: 'Closing & Handoff',          position: 12, estimated_days: 3,  visible_to_client: true,  is_required: true,  notify_client_on_start: false, notify_client_on_complete: true,  icon: 'KeyRound',      color: '#10b981', description: 'Final payment, keys delivered, warranty docs provided' },
      { name: 'Warranty Period',            position: 13, estimated_days: 365, visible_to_client: true, is_required: false, notify_client_on_start: true,  notify_client_on_complete: true,  icon: 'Shield',        color: '#6b7280', description: '12-month manufacturer warranty coverage' },
    ]

    # Clear existing phases and recreate (idempotent)
    standard.project_template_phases.destroy_all
    standard_phases.each { |phase| standard.project_template_phases.create!(phase) }
    standard.update_column(:phase_count, standard_phases.size)

    Rails.logger.info "  ✅ Standard Manufactured Home template: #{standard_phases.size} phases"

    # =====================================================================
    # FACTORY ORDER ONLY — No Installation (FOB Dealer Lot)
    # =====================================================================
    factory_order = company.project_templates.find_or_create_by!(name: 'Factory Order (No Install)') do |t|
      t.description = 'Factory-direct order where buyer handles their own installation. Home sold FOB dealer lot.'
      t.template_type = 'factory_order'
      t.is_default = false
      t.is_active = true
      t.created_by_id = company.users.first&.id
    end

    factory_phases = [
      { name: 'Finance Application',       position: 0, estimated_days: 14, visible_to_client: true,  is_required: true,  notify_client_on_complete: true,  icon: 'Landmark',      color: '#6366f1', description: 'Loan application submitted and under review' },
      { name: 'Purchase Agreement Signed',  position: 1, estimated_days: 7,  visible_to_client: true,  is_required: true,  notify_client_on_complete: true,  icon: 'FileSignature', color: '#8b5cf6', description: 'Purchase agreement and disclosures signed' },
      { name: 'Construction Authorized',    position: 2, estimated_days: 3,  visible_to_client: true,  is_required: true,  notify_client_on_complete: true,  icon: 'Hammer',        color: '#a855f7', description: 'Buyer authorizes factory to begin construction. Down payment non-refundable.' },
      { name: 'Color & Option Selections',  position: 3, estimated_days: 14, visible_to_client: true,  is_required: true,  notify_client_on_complete: true,  icon: 'Palette',       color: '#3b82f6', description: 'Interior and exterior color selections, appliance choices' },
      { name: 'Home In Production',         position: 4, estimated_days: 60, visible_to_client: true,  is_required: true,  notify_client_on_start: true, notify_client_on_complete: true, icon: 'Factory', color: '#0ea5e9', description: 'Home under construction at factory' },
      { name: 'Home Completed',             position: 5, estimated_days: 3,  visible_to_client: true,  is_required: true,  notify_client_on_complete: true,  icon: 'CircleCheck',   color: '#22c55e', description: 'Home completed and ready for transport' },
      { name: 'Balance Due & Payment',      position: 6, estimated_days: 7,  visible_to_client: true,  is_required: true,  notify_client_on_complete: true,  icon: 'DollarSign',    color: '#eab308', description: 'Remaining balance due before delivery' },
      { name: 'Transport Scheduled',        position: 7, estimated_days: 14, visible_to_client: true,  is_required: true,  notify_client_on_start: true, notify_client_on_complete: true, icon: 'Truck', color: '#f97316', description: 'Home scheduled for transport to buyer site' },
      { name: 'Delivered & Title Transfer', position: 8, estimated_days: 7,  visible_to_client: true,  is_required: true,  notify_client_on_complete: true,  icon: 'KeyRound',      color: '#10b981', description: 'Home delivered, title/MSO transferred, warranty docs provided' },
    ]

    factory_order.project_template_phases.destroy_all
    factory_phases.each { |phase| factory_order.project_template_phases.create!(phase) }
    factory_order.update_column(:phase_count, factory_phases.size)

    Rails.logger.info "  ✅ Factory Order template: #{factory_phases.size} phases"

    # =====================================================================
    # USED HOME — Shorter lifecycle
    # =====================================================================
    used_home = company.project_templates.find_or_create_by!(name: 'Used / Pre-Owned Home') do |t|
      t.description = 'Shorter lifecycle for used/pre-owned home sales with refurbishment and delivery'
      t.template_type = 'used_home'
      t.is_default = false
      t.is_active = true
      t.created_by_id = company.users.first&.id
    end

    used_phases = [
      { name: 'Purchase Agreement Signed',  position: 0, estimated_days: 7,  visible_to_client: true, is_required: true, notify_client_on_complete: true, icon: 'FileSignature', color: '#8b5cf6', description: 'Purchase agreement signed' },
      { name: 'Finance Approved',           position: 1, estimated_days: 14, visible_to_client: true, is_required: true, notify_client_on_complete: true, icon: 'Landmark',      color: '#6366f1', description: 'Financing approved or cash verified' },
      { name: 'Refurbishment',              position: 2, estimated_days: 21, visible_to_client: true, is_required: false, notify_client_on_start: true, notify_client_on_complete: true, icon: 'Wrench', color: '#3b82f6', description: 'Repairs and upgrades to prepare home for sale' },
      { name: 'Site Preparation',           position: 3, estimated_days: 14, visible_to_client: true, is_required: true, notify_client_on_complete: true, icon: 'Shovel',        color: '#14b8a6', description: 'Foundation and site work at delivery location' },
      { name: 'Delivery & Set',             position: 4, estimated_days: 7,  visible_to_client: true, is_required: true, notify_client_on_start: true, notify_client_on_complete: true, icon: 'Truck', color: '#22c55e', description: 'Home delivered and placed on foundation' },
      { name: 'Final Inspection',           position: 5, estimated_days: 7,  visible_to_client: true, is_required: true, notify_client_on_complete: true, icon: 'ShieldCheck',   color: '#ef4444', description: 'Inspection and walk-through' },
      { name: 'Closing & Handoff',          position: 6, estimated_days: 3,  visible_to_client: true, is_required: true, notify_client_on_complete: true, icon: 'KeyRound',      color: '#10b981', description: 'Keys delivered, warranty docs provided' },
    ]

    used_home.project_template_phases.destroy_all
    used_phases.each { |phase| used_home.project_template_phases.create!(phase) }
    used_home.update_column(:phase_count, used_phases.size)

    Rails.logger.info "  ✅ Used Home template: #{used_phases.size} phases"

    puts "✅ Project templates seeded: 3 templates (#{standard_phases.size + factory_phases.size + used_phases.size} total phases)"
  end
end
