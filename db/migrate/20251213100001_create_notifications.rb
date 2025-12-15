class CreateNotifications < ActiveRecord::Migration[7.0]
  def change
    create_table :notifications do |t|
      # Polymorphic recipient (User or Contact)
      t.string :recipient_type, null: false
      t.bigint :recipient_id, null: false
      
      # Tenant scoping
      t.bigint :company_id, null: false
      t.bigint :location_id
      
      # Notification details
      t.string :notification_type, null: false
      t.string :category, null: false # service, crm, sales, finance, system, broadcast
      t.string :priority, default: 'normal' # urgent, high, normal, low
      t.string :title, null: false
      t.text :message, null: false
      
      # Polymorphic notifiable (what this notification is about)
      t.string :notifiable_type
      t.bigint :notifiable_id
      
      # Who triggered this notification (optional)
      t.string :actor_type
      t.bigint :actor_id
      
      # Read status
      t.boolean :read, default: false, null: false
      t.datetime :read_at
      
      # Delivery tracking
      t.boolean :email_sent, default: false
      t.datetime :email_sent_at
      t.boolean :sms_sent, default: false
      t.datetime :sms_sent_at
      
      # Action link (computed or explicit)
      t.string :action_url
      t.string :action_text
      t.jsonb :action_data, default: {}
      
      # Additional metadata
      t.jsonb :metadata, default: {}
      
      t.timestamps
    end
    
    # Indexes for performance
    add_index :notifications, [:recipient_type, :recipient_id, :read], name: 'index_notifications_on_recipient_and_read'
    add_index :notifications, [:recipient_type, :recipient_id, :created_at], name: 'index_notifications_on_recipient_and_created'
    add_index :notifications, [:company_id, :notification_type]
    add_index :notifications, [:company_id, :created_at]
    add_index :notifications, [:notifiable_type, :notifiable_id]
    add_index :notifications, :location_id
    add_index :notifications, :category
    add_index :notifications, :priority
  end
end
