# app/models/concerns/notifiable_note.rb
module NotifiableNote
  extend ActiveSupport::Concern
  
  included do
    after_create :notify_mentioned_users
  end
  
  private
  
  def notify_mentioned_users
    return unless body.present?
    
    # Parse @mentions from note body
    # Supports: @username or @"Full Name"
    mentions = body.scan(/@(\w+)|@"([^"]+)"/).flatten.compact
    
    return if mentions.empty?
    
    # Find users by username or name
    mentioned_users = User.where(company_id: company_id)
                         .where('username IN (?) OR CONCAT(first_name, \' \', last_name) IN (?)', mentions, mentions)
    
    mentioned_users.each do |user|
      next if user == Current.user # Don't notify yourself
      
      NotificationService.create(
        recipient: user,
        notification_type: :mention_received,
        notifiable: self,
        actor: Current.user,
        message: "#{Current.user&.name || 'Someone'} mentioned you in a note",
        deliver_now: true,
        company_id: company_id,
        location_id: location_id
      )
    end
  end
end
