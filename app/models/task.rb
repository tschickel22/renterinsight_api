class Task < ApplicationRecord
  # ===== ASSOCIATIONS =====
  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :taskable, polymorphic: true, optional: true
  belongs_to :assigned_to, class_name: 'User', optional: true
  
  # ===== ENUMS =====
  enum :status, {
    pending: 0,
    in_progress: 1,
    on_hold: 2,
    completed: 3,
    cancelled: 4
  }, prefix: true
  
  enum :priority, {
    low: 0,
    medium: 1,
    high: 2,
    urgent: 3
  }, prefix: true
  
  # ===== VALIDATIONS =====
  validates :title, presence: true
  validates :status, presence: true
  validates :priority, presence: true
  validates :company_id, presence: true
  
  # ===== SCOPES =====
  scope :for_current_location, -> {
    if Current.location_filtered? && Current.location_id.present?
      where(location_id: Current.location_id)
    else
      all
    end
  }
  
  scope :active, -> { where.not(status: [:completed, :cancelled]) }
  scope :overdue, -> { where('due_date < ? AND status NOT IN (?)', Time.current, [statuses[:completed], statuses[:cancelled]]) }
  scope :due_soon, -> { where('due_date BETWEEN ? AND ? AND status NOT IN (?)', Time.current, 7.days.from_now, [statuses[:completed], statuses[:cancelled]]) }
  scope :by_module, ->(module_name) { where(task_module: module_name) }
  scope :assigned_to_user, ->(user_id) { where(assigned_to_id: user_id) }
  scope :unassigned, -> { where(assigned_to_id: nil) }
  
  # Order by priority (urgent first) then due date
  scope :by_priority_and_date, -> {
    order(Arel.sql("
      CASE priority
        WHEN #{priorities[:urgent]} THEN 1
        WHEN #{priorities[:high]} THEN 2
        WHEN #{priorities[:medium]} THEN 3
        WHEN #{priorities[:low]} THEN 4
      END,
      CASE 
        WHEN due_date < NOW() AND status NOT IN (#{statuses[:completed]}, #{statuses[:cancelled]}) THEN 0
        ELSE 1
      END,
      due_date ASC NULLS LAST
    "))
  }
  
  # ===== CALLBACKS =====
  before_save :set_completed_at
  before_save :set_location_from_taskable
  
  # ===== INSTANCE METHODS =====
  
  def overdue?
    due_date.present? && 
    due_date < Time.current && 
    !status_completed? && 
    !status_cancelled?
  end
  
  def complete!
    update!(status: :completed, completed_at: Time.current)
  end
  
  def reopen!
    update!(status: :pending, completed_at: nil)
  end
  
  # Generate a deep link to the related entity
  def generate_link
    return link if link.present?
    
    # Keep this list in sync with WorkqueueService#task_deep_link — both walk
    # taskable_type to build the FE deep link. ServiceOps mounts tickets at
    # /service/:ticketId, not /service/tickets/:id.
    case taskable_type
    when 'Lead'           then "/crm/leads/#{taskable_id}"
    when 'ServiceTicket'  then "/service/#{taskable_id}"
    when 'Deal'           then "/deals/#{taskable_id}?tab=activities"
    when 'Contact'        then "/contacts/#{taskable_id}?tab=activities"
    when 'Account'        then "/accounts/#{taskable_id}?tab=activities"
    when 'Quote'          then "/quotes/#{taskable_id}"
    when 'Delivery'       then "/delivery/#{taskable_id}"
    when 'WarrantyClaim'  then "/warranty-mgmt/claims/#{taskable_id}"
    else nil
    end
  end
  
  # Serialize for API responses
  def as_json(options = {})
    super(options.merge(
      methods: [:overdue?],
      include: {
        assigned_to: { only: [:id, :name, :email] }
      }
    ))
  end
  
  private
  
  def set_completed_at
    if status_completed? && completed_at.nil?
      self.completed_at = Time.current
    elsif !status_completed? && completed_at.present?
      self.completed_at = nil
    end
  end
  
  def set_location_from_taskable
    # Auto-assign location from taskable if not set
    if location_id.nil? && taskable.present? && taskable.respond_to?(:location_id)
      self.location_id = taskable.location_id
    end
  end
end
