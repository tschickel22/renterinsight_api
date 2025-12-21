# app/mailers/user_mailer.rb (or create if doesn't exist)
class UserMailer < ApplicationMailer
  default from: ENV.fetch('DEFAULT_FROM_EMAIL', 'noreply@renterinsight.com')

  def activity_reminder(activity, user)
    @activity = activity
    @user = user
    @entity_name = get_entity_name(activity)
    
    mail(
      to: user.email,
      subject: "Reminder: #{activity.subject}"
    )
  end
  
  private
  
  def get_entity_name(activity)
    if activity.respond_to?(:lead) && activity.lead
      "#{activity.lead.first_name} #{activity.lead.last_name}".strip
    elsif activity.respond_to?(:contact) && activity.contact
      "#{activity.contact.first_name} #{activity.contact.last_name}".strip
    elsif activity.respond_to?(:account) && activity.account
      activity.account.name
    else
      'Unknown'
    end
  end
end
