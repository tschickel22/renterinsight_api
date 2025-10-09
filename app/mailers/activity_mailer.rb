# frozen_string_literal: true

class ActivityMailer < ApplicationMailer
  default from: 'notifications@renterinsight.com'

  def activity_notification(activity, user)
    @activity = activity
    @user = user
    @lead = activity.lead
    
    mail(
      to: user.email,
      subject: "#{activity_type_label}: #{activity.subject}"
    )
  end

  def reminder_notification(activity)
    @activity = activity
    @user = activity.assigned_to
    @lead = activity.lead
    
    mail(
      to: @user.email,
      subject: "Reminder: #{activity.subject}"
    )
  end

  private

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
