# CommunicationLog scopes
if defined?(CommunicationLog)
  CommunicationLog.class_eval do
    scope :for_lead, ->(lead_id) { where(lead_id: lead_id) }
    scope :recent,   -> { order(Arel.sql("COALESCE(sent_at, created_at) DESC")).limit(100) }
  end
end

# Tag helpers
if defined?(Tag)
  Tag.class_eval do
    scope :active, -> { where(is_active: true) } unless respond_to?(:active)
    def usage_count; self[:usage_count].presence || 0; end
    # In SQLite, store arrays as JSON in a text column
    if column_names.include?('tag_type')
      begin
        serialize :tag_type, JSON
      rescue
        # Rails 7+ with attributes API might not need this; ignore if unsupported
      end
    end
  end
end

# TagAssignment scope
if defined?(TagAssignment)
  TagAssignment.class_eval do
    belongs_to :tag unless reflect_on_association(:tag)
    scope :for_entity, ->(etype, eid) { where(entity_type: etype, entity_id: eid) }
  end
end

# Reminder STI safety if a 'type' column exists
if defined?(Reminder)
  Reminder.inheritance_column = :_type_disabled if Reminder.column_names.include?('type')
end
