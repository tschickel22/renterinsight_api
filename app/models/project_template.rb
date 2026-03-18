# frozen_string_literal: true

class ProjectTemplate < ApplicationRecord
  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :created_by, class_name: 'User', optional: true

  has_many :project_template_phases, -> { order(:position) }, dependent: :destroy
  has_many :projects, dependent: :nullify

  # Validations
  validates :name, presence: true
  validates :template_type, inclusion: {
    in: %w[standard land_home factory_order used_home service_project],
    allow_blank: true
  }

  # Scopes
  scope :active, -> { where(is_active: true, is_deleted: [false, nil]) }
  scope :defaults, -> { where(is_default: true) }
  scope :by_type, ->(type) { where(template_type: type) if type.present? }

  # Callbacks
  before_save :update_phase_count
  after_save :ensure_single_default, if: :is_default?

  # Duplicate a template (for customization)
  def duplicate!(new_name: nil)
    new_template = dup
    new_template.name = new_name || "#{name} (Copy)"
    new_template.is_default = false
    new_template.save!

    project_template_phases.each do |phase|
      new_phase = phase.dup
      new_phase.project_template = new_template
      new_phase.save!
    end

    new_template.reload
  end

  # Create a project from this template, optionally linked to a deal
  def create_project!(company:, deal: nil, name: nil, owner: nil, created_by: nil)
    project_name = name || (deal ? "#{deal.customer_display_name} - #{deal.vehicle&.display_name || deal.name}" : self.name)

    project = Project.new(
      company: company,
      location: deal&.location || self.location,
      deal: deal,
      project_template: self,
      name: project_name,
      status: 'active',
      owner_id: owner&.id || deal&.owner_id,
      created_by_id: created_by&.id,
      client_visible: true
    )

    # Denormalize customer info from deal
    if deal
      project.customer_name = deal.customer_display_name
      project.customer_email = deal.contact&.email
      project.customer_phone = deal.contact&.phone

      # Denormalize home/vehicle info
      if deal.vehicle
        project.vehicle_id = deal.vehicle_id
        project.home_make = deal.vehicle.make
        project.home_model = deal.vehicle.model
        project.home_serial_number = deal.vehicle.serial_number
      end

      # Delivery address
      project.delivery_street = deal.delivery_street
      project.delivery_city = deal.delivery_city
      project.delivery_state = deal.delivery_state
      project.delivery_zip = deal.delivery_zip
    end

    project.save!

    # Create phases from template (with tasks)
    project_template_phases.each do |template_phase|
      phase = project.project_phases.create!(
        company: company,
        name: template_phase.name,
        description: template_phase.description,
        position: template_phase.position,
        status: 'not_started',
        is_required: template_phase.is_required,
        visible_to_client: template_phase.visible_to_client,
        notify_client_on_start: template_phase.notify_client_on_start,
        notify_client_on_complete: template_phase.notify_client_on_complete,
        estimated_days: template_phase.estimated_days,
        icon: template_phase.icon,
        color: template_phase.color
      )
      # Copy simple tasks from template phase
      template_phase.project_template_phase_tasks.ordered.each do |task|
        phase.project_phase_tasks.create!(
          company: company,
          name: task.name,
          position: task.position,
          is_required: task.is_required,
          status: 'pending'
        )
      end

      # Copy rich tasks from default_tasks JSON (Phase 2A)
      # Handles both seed format (title/checklist) and editor format (name/checklist_items)
      (template_phase.default_tasks || []).each_with_index do |task_data, task_idx|
        task_data = task_data.with_indifferent_access
        task_title = task_data[:title] || task_data[:name]
        next if task_title.blank?

        rich_task = phase.tasks.create!(
          company: company,
          project: project,
          title: task_title,
          description: task_data[:description],
          task_type: task_data[:task_type] || 'general',
          estimated_hours: task_data[:estimated_hours],
          position: task_data[:position] || task_idx,
          status: 'pending',
          priority: 'medium'
        )

        checklist_items = task_data[:checklist] || task_data[:checklist_items] || []
        if checklist_items.present? && checklist_items.is_a?(Array)
          checklist = rich_task.checklists.create!(title: 'Checklist', position: 0)
          checklist_items.each_with_index do |item_title, item_idx|
            checklist.items.create!(title: item_title, position: item_idx)
          end
        end
      end
    end

    # Update cached counts and set first phase
    project.reload
    project.update_progress_cache!

    # Link deal back to project
    deal.update_column(:project_id, project.id) if deal

    project
  end

  # ============================================================================
  # CLASS METHOD: Seed default templates for a company
  # ============================================================================
  def self.seed_defaults!(company)
    Rails.logger.info "[ProjectTemplate] Seeding default templates for Company #{company.id} (#{company.name})"

    # Standard Manufactured Home
    standard = company.project_templates.find_or_create_by!(name: 'Standard Manufactured Home') do |t|
      t.description = 'Full lifecycle for a new manufactured home purchase with land prep, delivery, and installation'
      t.template_type = 'land_home'
      t.is_default = true
      t.is_active = true
      t.created_by_id = company.users.first&.id
    end
    standard_phases = [
      { name: 'Finance Application',          position: 0,  estimated_days: 14,  visible_to_client: true,  is_required: true,  notify_client_on_start: false, notify_client_on_complete: true,  icon: 'Landmark',       color: '#6366f1', description: 'Loan application submitted and under review',
        default_tasks: [
          { title: 'Submit loan application', task_type: 'general', estimated_hours: 2, checklist: ['Collect buyer financials', 'Run credit check', 'Submit to lender'] },
          { title: 'Receive pre-approval', task_type: 'milestone', estimated_hours: 1 },
        ] },
      { name: 'Purchase Agreement Signed',    position: 1,  estimated_days: 7,   visible_to_client: true,  is_required: true,  notify_client_on_start: false, notify_client_on_complete: true,  icon: 'FileSignature',  color: '#8b5cf6', description: 'Purchase agreement executed by all parties',
        default_tasks: [
          { title: 'Prepare purchase agreement', task_type: 'general', estimated_hours: 2, checklist: ['Buyer info complete', 'Home specs confirmed', 'Pricing finalized', 'Trade-in documented'] },
          { title: 'Buyer signs PA', task_type: 'milestone', estimated_hours: 1 },
          { title: 'Collect deposit', task_type: 'general', estimated_hours: 1 },
        ] },
      { name: 'Home Ordered / In Production', position: 2,  estimated_days: 60,  visible_to_client: true,  is_required: true,  notify_client_on_start: true,  notify_client_on_complete: true,  icon: 'Factory',        color: '#a855f7', description: 'Home ordered from manufacturer and in production',
        default_tasks: [
          { title: 'Submit factory order', task_type: 'general', estimated_hours: 2 },
          { title: 'Color and option selections', task_type: 'general', estimated_hours: 4, checklist: ['Interior colors', 'Cabinet style', 'Countertops', 'Flooring', 'Siding and shingles', 'Appliances'] },
          { title: 'Confirm production schedule', task_type: 'milestone', estimated_hours: 1 },
          { title: 'Monitor production status', task_type: 'general', estimated_hours: 2 },
        ] },
      { name: 'Home Arrives at Dealer',       position: 3,  estimated_days: 14,  visible_to_client: true,  is_required: true,  notify_client_on_start: false, notify_client_on_complete: true,  icon: 'Truck',          color: '#3b82f6', description: 'Home delivered to dealer lot for inspection',
        default_tasks: [
          { title: 'Schedule transport from factory', task_type: 'general', estimated_hours: 2 },
          { title: 'Receive home on lot', task_type: 'milestone', estimated_hours: 4 },
          { title: 'Verify serial numbers and docs', task_type: 'general', estimated_hours: 1 },
        ] },
      { name: 'Receiving Inspection (PDI)',   position: 4,  estimated_days: 3,   visible_to_client: false, is_required: true,  notify_client_on_start: false, notify_client_on_complete: false, icon: 'ClipboardCheck', color: '#0ea5e9', description: 'Pre-delivery inspection and quality check',
        default_tasks: [
          { title: 'Exterior inspection', task_type: 'inspection_required', estimated_hours: 2, checklist: ['Roof condition', 'Siding intact', 'Windows sealed', 'No transport damage'] },
          { title: 'Interior inspection', task_type: 'inspection_required', estimated_hours: 2, checklist: ['Walls and ceiling', 'Flooring', 'Plumbing fixtures', 'Electrical panels', 'Appliances'] },
          { title: 'Document deficiencies', task_type: 'general', estimated_hours: 1 },
          { title: 'Submit warranty claims', task_type: 'general', estimated_hours: 1 },
        ] },
      { name: 'Land Prep & Permits',          position: 5,  estimated_days: 30,  visible_to_client: true,  is_required: true,  notify_client_on_start: true,  notify_client_on_complete: true,  icon: 'Shovel',         color: '#14b8a6', description: 'Foundation, utilities, and building permits',
        default_tasks: [
          { title: 'Site evaluation and soil test', task_type: 'general', estimated_hours: 4, checklist: ['Soil bearing test', 'Drainage assessment', 'Grade evaluation', 'Access road check'] },
          { title: 'Building permit application', task_type: 'permit_required', estimated_hours: 2, checklist: ['Submit site plan', 'Submit foundation details', 'Submit utility plans', 'Pay permit fees'] },
          { title: 'Foundation construction', task_type: 'inspection_required', estimated_hours: 40, checklist: ['Forms set', 'Rebar placed', 'Concrete poured', 'Cure time complete', 'Anchors installed'] },
          { title: 'Foundation inspection', task_type: 'inspection_required', estimated_hours: 2 },
          { title: 'Utility trenching', task_type: 'general', estimated_hours: 16, checklist: ['Water line', 'Sewer line', 'Electric conduit', 'Gas line'] },
        ] },
      { name: 'Home Delivered to Site',       position: 6,  estimated_days: 7,   visible_to_client: true,  is_required: true,  notify_client_on_start: true,  notify_client_on_complete: true,  icon: 'MapPin',         color: '#22c55e', description: 'Home transported and placed on foundation',
        default_tasks: [
          { title: 'Verify delivery path clearance', task_type: 'general', estimated_hours: 2, checklist: ['Road width ok', 'No low wires', 'Turn radius clear', 'Ground firm'] },
          { title: 'Home delivery and placement', task_type: 'milestone', estimated_hours: 8 },
          { title: 'Level and anchor home', task_type: 'general', estimated_hours: 8, checklist: ['Pier/block placement', 'Home leveled', 'Tie-downs secured'] },
          { title: 'Remove tires and axles', task_type: 'general', estimated_hours: 4 },
        ] },
      { name: 'Installation & Set',           position: 7,  estimated_days: 14,  visible_to_client: true,  is_required: true,  notify_client_on_start: true,  notify_client_on_complete: true,  icon: 'Wrench',         color: '#84cc16', description: 'Leveling, blocking, skirting, and exterior finish',
        default_tasks: [
          { title: 'Section joining and marriage line', task_type: 'general', estimated_hours: 16, checklist: ['Sections aligned', 'Gaskets sealed', 'Roof ridge connected', 'Floor alignment verified'] },
          { title: 'Skirting installation', task_type: 'general', estimated_hours: 12, checklist: ['Material installed', 'Access panels placed', 'Ventilation adequate'] },
          { title: 'Steps and deck', task_type: 'general', estimated_hours: 16 },
          { title: 'Exterior trim', task_type: 'general', estimated_hours: 8 },
        ] },
      { name: 'Utility Connections',          position: 8,  estimated_days: 10,  visible_to_client: true,  is_required: true,  notify_client_on_start: false, notify_client_on_complete: true,  icon: 'Zap',            color: '#eab308', description: 'Electrical, plumbing, HVAC, water, sewer hookups',
        default_tasks: [
          { title: 'Electrical connections', task_type: 'inspection_required', estimated_hours: 8, checklist: ['Panel connected', 'Crossovers done', 'All circuits tested', 'GFCI verified'] },
          { title: 'Electrical inspection', task_type: 'inspection_required', estimated_hours: 2 },
          { title: 'Plumbing connections', task_type: 'inspection_required', estimated_hours: 8, checklist: ['Water connected', 'Sewer connected', 'Crossovers done', 'Fixtures tested'] },
          { title: 'Plumbing inspection', task_type: 'inspection_required', estimated_hours: 2 },
          { title: 'HVAC installation', task_type: 'general', estimated_hours: 12, checklist: ['AC unit installed', 'Ductwork connected', 'Thermostat set', 'System tested'] },
        ] },
      { name: 'Interior Finish',              position: 9,  estimated_days: 14,  visible_to_client: true,  is_required: true,  notify_client_on_start: false, notify_client_on_complete: true,  icon: 'PaintBucket',    color: '#f97316', description: 'Drywall marriage line, trim, carpet, appliances',
        default_tasks: [
          { title: 'Drywall marriage line close-up', task_type: 'general', estimated_hours: 16, checklist: ['Tape and texture seams', 'Repair transport cracks', 'Touch-up paint'] },
          { title: 'Interior trim', task_type: 'general', estimated_hours: 16 },
          { title: 'Carpet installation', task_type: 'general', estimated_hours: 8 },
          { title: 'Appliance install and test', task_type: 'general', estimated_hours: 8, checklist: ['Range connected', 'Refrigerator placed', 'Dishwasher connected', 'Washer/dryer hookups'] },
          { title: 'Final cleaning', task_type: 'general', estimated_hours: 8 },
        ] },
      { name: 'Final Inspection',             position: 10, estimated_days: 7,   visible_to_client: true,  is_required: true,  notify_client_on_start: false, notify_client_on_complete: true,  icon: 'ShieldCheck',    color: '#ef4444', description: 'County or state building inspector sign-off',
        default_tasks: [
          { title: 'Schedule final inspection', task_type: 'general', estimated_hours: 1 },
          { title: 'Final building inspection', task_type: 'inspection_required', estimated_hours: 4 },
          { title: 'Certificate of occupancy', task_type: 'milestone', estimated_hours: 1 },
        ] },
      { name: 'Punch List & Walk-Through',    position: 11, estimated_days: 7,   visible_to_client: true,  is_required: true,  notify_client_on_start: true,  notify_client_on_complete: true,  icon: 'ListChecks',     color: '#ec4899', description: 'Buyer walk-through and punch list items',
        default_tasks: [
          { title: 'Buyer walkthrough', task_type: 'general', estimated_hours: 4, checklist: ['All systems functioning', 'Cosmetic items noted', 'Punch list created', 'Keys provided'] },
          { title: 'Complete punch list items', task_type: 'general', estimated_hours: 8 },
          { title: 'Warranty docs reviewed', task_type: 'general', estimated_hours: 1, checklist: ['Manufacturer warranty', '30-day cosmetic window', '12-month start date'] },
        ] },
      { name: 'Closing & Handoff',            position: 12, estimated_days: 3,   visible_to_client: true,  is_required: true,  notify_client_on_start: false, notify_client_on_complete: true,  icon: 'KeyRound',       color: '#10b981', description: 'Final payment, keys delivered, warranty docs provided',
        default_tasks: [
          { title: 'Final payment collection', task_type: 'milestone', estimated_hours: 1 },
          { title: 'Title transfer', task_type: 'general', estimated_hours: 2 },
          { title: 'Warranty registration', task_type: 'general', estimated_hours: 1 },
        ] },
      { name: 'Warranty Period',              position: 13, estimated_days: 365, visible_to_client: true,  is_required: false, notify_client_on_start: true,  notify_client_on_complete: true,  icon: 'Shield',         color: '#6b7280', description: '12-month manufacturer warranty coverage',
        default_tasks: [
          { title: 'Record warranty start date', task_type: 'general', estimated_hours: 1 },
          { title: 'Schedule 30-day follow-up', task_type: 'general', estimated_hours: 1 },
          { title: 'Schedule 6-month check-in', task_type: 'general', estimated_hours: 1 },
          { title: 'Schedule 11-month walk-through', task_type: 'general', estimated_hours: 1 },
        ] },
    ]
    standard.project_template_phases.destroy_all
    standard_phases.each { |p| standard.project_template_phases.create!(p) }
    standard.update_column(:phase_count, standard_phases.size)

    # Factory Order (No Install)
    factory = company.project_templates.find_or_create_by!(name: 'Factory Order (No Install)') do |t|
      t.description = 'Factory-direct order where buyer handles their own installation. Home sold FOB dealer lot.'
      t.template_type = 'factory_order'
      t.is_default = false
      t.is_active = true
      t.created_by_id = company.users.first&.id
    end
    factory_phases = [
      { name: 'Finance Application',        position: 0, estimated_days: 14, visible_to_client: true, is_required: true,  notify_client_on_start: false, notify_client_on_complete: true,  icon: 'Landmark',      color: '#6366f1', description: 'Loan application submitted and under review',
        default_tasks: [
          { title: 'Submit loan application', task_type: 'general', estimated_hours: 2, checklist: ['Collect buyer financials', 'Run credit check', 'Submit to lender'] },
          { title: 'Receive pre-approval', task_type: 'milestone', estimated_hours: 1 },
        ] },
      { name: 'Purchase Agreement Signed',  position: 1, estimated_days: 7,  visible_to_client: true, is_required: true,  notify_client_on_start: false, notify_client_on_complete: true,  icon: 'FileSignature', color: '#8b5cf6', description: 'Purchase agreement and disclosures signed',
        default_tasks: [
          { title: 'Prepare purchase agreement', task_type: 'general', estimated_hours: 2, checklist: ['Buyer info complete', 'Home specs confirmed', 'Pricing finalized'] },
          { title: 'Buyer signs PA', task_type: 'milestone', estimated_hours: 1 },
          { title: 'Collect deposit', task_type: 'general', estimated_hours: 1 },
        ] },
      { name: 'Construction Authorized',    position: 2, estimated_days: 3,  visible_to_client: true, is_required: true,  notify_client_on_start: false, notify_client_on_complete: true,  icon: 'Hammer',        color: '#a855f7', description: 'Buyer authorizes factory to begin construction',
        default_tasks: [
          { title: 'Buyer authorizes construction', task_type: 'milestone', estimated_hours: 1 },
          { title: 'Down payment confirmed non-refundable', task_type: 'general', estimated_hours: 1 },
        ] },
      { name: 'Color & Option Selections',  position: 3, estimated_days: 14, visible_to_client: true, is_required: true,  notify_client_on_start: false, notify_client_on_complete: true,  icon: 'Palette',       color: '#3b82f6', description: 'Interior and exterior color selections',
        default_tasks: [
          { title: 'Interior color selections', task_type: 'general', estimated_hours: 2, checklist: ['Walls', 'Trim', 'Doors', 'Cabinets', 'Countertops'] },
          { title: 'Exterior color selections', task_type: 'general', estimated_hours: 2, checklist: ['Siding', 'Shingles', 'Trim color', 'Shutters'] },
          { title: 'Appliance selections', task_type: 'general', estimated_hours: 1 },
        ] },
      { name: 'Home In Production',         position: 4, estimated_days: 60, visible_to_client: true, is_required: true,  notify_client_on_start: true,  notify_client_on_complete: true,  icon: 'Factory',       color: '#0ea5e9', description: 'Home under construction at factory',
        default_tasks: [
          { title: 'Submit factory order', task_type: 'general', estimated_hours: 2 },
          { title: 'Confirm production schedule', task_type: 'milestone', estimated_hours: 1 },
          { title: 'Monitor production status', task_type: 'general', estimated_hours: 2 },
        ] },
      { name: 'Home Completed',             position: 5, estimated_days: 3,  visible_to_client: true, is_required: true,  notify_client_on_start: false, notify_client_on_complete: true,  icon: 'CircleCheck',   color: '#22c55e', description: 'Home completed and ready for transport',
        default_tasks: [
          { title: 'Factory completion confirmed', task_type: 'milestone', estimated_hours: 1 },
          { title: 'Quality photos from factory', task_type: 'general', estimated_hours: 1 },
        ] },
      { name: 'Balance Due & Payment',      position: 6, estimated_days: 7,  visible_to_client: true, is_required: true,  notify_client_on_start: false, notify_client_on_complete: true,  icon: 'DollarSign',    color: '#eab308', description: 'Remaining balance due before delivery',
        default_tasks: [
          { title: 'Generate final invoice', task_type: 'general', estimated_hours: 1 },
          { title: 'Collect remaining balance', task_type: 'milestone', estimated_hours: 1 },
        ] },
      { name: 'Transport Scheduled',        position: 7, estimated_days: 14, visible_to_client: true, is_required: true,  notify_client_on_start: true,  notify_client_on_complete: true,  icon: 'Truck',         color: '#f97316', description: 'Home scheduled for transport to buyer site',
        default_tasks: [
          { title: 'Book transport company', task_type: 'general', estimated_hours: 2 },
          { title: 'Arrange highway escorts', task_type: 'general', estimated_hours: 1 },
          { title: 'Confirm delivery date with buyer', task_type: 'general', estimated_hours: 1 },
        ] },
      { name: 'Delivered & Title Transfer', position: 8, estimated_days: 7,  visible_to_client: true, is_required: true,  notify_client_on_start: false, notify_client_on_complete: true,  icon: 'KeyRound',      color: '#10b981', description: 'Home delivered, title/MSO transferred',
        default_tasks: [
          { title: 'Home delivered to buyer', task_type: 'milestone', estimated_hours: 4 },
          { title: 'MSO/title transfer', task_type: 'general', estimated_hours: 2 },
          { title: 'Tires and axles bill of sale', task_type: 'general', estimated_hours: 1 },
        ] },
    ]
    factory.project_template_phases.destroy_all
    factory_phases.each { |p| factory.project_template_phases.create!(p) }
    factory.update_column(:phase_count, factory_phases.size)

    # Used / Pre-Owned Home
    used = company.project_templates.find_or_create_by!(name: 'Used / Pre-Owned Home') do |t|
      t.description = 'Shorter lifecycle for used/pre-owned home sales with refurbishment and delivery'
      t.template_type = 'used_home'
      t.is_default = false
      t.is_active = true
      t.created_by_id = company.users.first&.id
    end
    used_phases = [
      { name: 'Purchase Agreement Signed', position: 0, estimated_days: 7,  visible_to_client: true, is_required: true,  notify_client_on_start: false, notify_client_on_complete: true, icon: 'FileSignature', color: '#8b5cf6', description: 'Purchase agreement signed',
        default_tasks: [
          { title: 'Prepare purchase agreement', task_type: 'general', estimated_hours: 2, checklist: ['Buyer info complete', 'Home specs confirmed', 'Pricing finalized', 'Trade-in documented'] },
          { title: 'Buyer signs PA', task_type: 'milestone', estimated_hours: 1 },
          { title: 'Collect deposit', task_type: 'general', estimated_hours: 1 },
        ] },
      { name: 'Finance Approved',          position: 1, estimated_days: 14, visible_to_client: true, is_required: true,  notify_client_on_start: false, notify_client_on_complete: true, icon: 'Landmark',      color: '#6366f1', description: 'Financing approved or cash verified',
        default_tasks: [
          { title: 'Lender approval received', task_type: 'milestone', estimated_hours: 1 },
          { title: 'Verify loan terms with buyer', task_type: 'general', estimated_hours: 1 },
        ] },
      { name: 'Refurbishment',             position: 2, estimated_days: 21, visible_to_client: true, is_required: false, notify_client_on_start: true,  notify_client_on_complete: true, icon: 'Wrench',        color: '#3b82f6', description: 'Repairs and upgrades to prepare home for sale',
        default_tasks: [
          { title: 'Assess repair needs', task_type: 'general', estimated_hours: 4, checklist: ['Structural check', 'Plumbing check', 'Electrical check', 'Cosmetic assessment'] },
          { title: 'Complete repairs', task_type: 'general', estimated_hours: 20 },
          { title: 'Quality inspection after repairs', task_type: 'inspection_required', estimated_hours: 2 },
        ] },
      { name: 'Site Preparation',          position: 3, estimated_days: 14, visible_to_client: true, is_required: true,  notify_client_on_start: false, notify_client_on_complete: true, icon: 'Shovel',        color: '#14b8a6', description: 'Foundation and site work at delivery location',
        default_tasks: [
          { title: 'Grade and level site', task_type: 'general', estimated_hours: 8 },
          { title: 'Foundation work', task_type: 'inspection_required', estimated_hours: 24 },
          { title: 'Utility rough-ins', task_type: 'general', estimated_hours: 16 },
        ] },
      { name: 'Delivery & Set',            position: 4, estimated_days: 7,  visible_to_client: true, is_required: true,  notify_client_on_start: true,  notify_client_on_complete: true, icon: 'Truck',         color: '#22c55e', description: 'Home delivered and placed on foundation',
        default_tasks: [
          { title: 'Deliver and place home', task_type: 'milestone', estimated_hours: 8 },
          { title: 'Level, anchor, and skirt', task_type: 'general', estimated_hours: 12 },
          { title: 'Utility connections', task_type: 'inspection_required', estimated_hours: 16 },
        ] },
      { name: 'Final Inspection',          position: 5, estimated_days: 7,  visible_to_client: true, is_required: true,  notify_client_on_start: false, notify_client_on_complete: true, icon: 'ShieldCheck',   color: '#ef4444', description: 'Inspection and walk-through',
        default_tasks: [
          { title: 'Schedule final inspection', task_type: 'general', estimated_hours: 1 },
          { title: 'Final building inspection', task_type: 'inspection_required', estimated_hours: 4 },
          { title: 'Buyer walkthrough', task_type: 'general', estimated_hours: 4, checklist: ['All systems functioning', 'Cosmetic items noted', 'Punch list created', 'Keys provided'] },
        ] },
      { name: 'Closing & Handoff',         position: 6, estimated_days: 3,  visible_to_client: true, is_required: true,  notify_client_on_start: false, notify_client_on_complete: true, icon: 'KeyRound',      color: '#10b981', description: 'Keys delivered, warranty docs provided',
        default_tasks: [
          { title: 'Final payment collection', task_type: 'milestone', estimated_hours: 1 },
          { title: 'Title transfer', task_type: 'general', estimated_hours: 2 },
          { title: 'Warranty registration', task_type: 'general', estimated_hours: 1 },
        ] },
    ]
    used.project_template_phases.destroy_all
    used_phases.each { |p| used.project_template_phases.create!(p) }
    used.update_column(:phase_count, used_phases.size)

    Rails.logger.info "[ProjectTemplate] Seeded 3 default templates for Company #{company.id}"
  end

  private

  def update_phase_count
    self.phase_count = project_template_phases.size
  end

  # Ensure only one default template per company + template_type
  def ensure_single_default
    ProjectTemplate.where(company_id: company_id, template_type: template_type, is_default: true)
                   .where.not(id: id)
                   .update_all(is_default: false)
  end
end
