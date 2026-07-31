# app/mailers/user_mailer.rb (or create if doesn't exist)
class UserMailer < ApplicationMailer
  # Lambda, not a literal: `default` is evaluated at class-load time, so a
  # bare value would freeze whatever the From address was at boot and ignore
  # later Platform Admin changes. This previously read ENV only and never
  # consulted the brand kernel at all.
  default from: -> { Brand.from_email }

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
