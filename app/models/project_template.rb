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
      # Copy tasks from template phase
      template_phase.project_template_phase_tasks.ordered.each do |task|
        phase.project_phase_tasks.create!(
          company: company,
          name: task.name,
          position: task.position,
          is_required: task.is_required,
          status: 'pending'
        )
      end
    end

    # Update cached counts and set first phase
    project.reload
    project.update_progress_cache!

    # Link deal back to project
    deal.update_column(:project_id, project.id) if deal

    project
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
