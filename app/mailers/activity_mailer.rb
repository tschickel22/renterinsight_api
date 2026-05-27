# frozen_string_literal: true

class ActivityMailer < ApplicationMailer
  # No hardcoded from: — uses ApplicationMailer#default_from_address waterfall
  # (User → Location → Company → Platform → ActionMailer default)
  helper_method :activity_type_label

  def activity_notification(activity, user)
    @activity = activity
    @user = user
    @lead = activity.lead
    @company = @lead&.company || Company.find_by(id: user.company_id)
    
    mail(
      to: user.email,
      from: default_from_address,
      subject: "#{activity_type_label}: #{activity.subject}"
    )
  end

  def reminder_notification(activity)
    @activity = activity
    @user = activity.assigned_to
    @lead = activity.lead
    @company = @lead&.company || Company.find_by(id: @user&.company_id)
    
    mail(
      to: @user.email,
      from: default_from_address,
      subject: "Reminder: #{activity.subject}"
    )
  end

  def activity_type_label
    case @activity.activity_type
    when 'task'
      'New Task'
    when 'meeting'
      'Meeting Scheduled'
    when 'call'
      'Call Scheduled'
    when 'reminder'
      'Reminder'
    else
      'Activity'
    end
  end
end
