# app/controllers/api/v1/notification_settings_controller.rb
class Api::V1::NotificationSettingsController < ApplicationController
  before_action :authenticate
  
  def show
    render json: {
      notification_settings: current_user.notification_settings || default_settings
    }
  end
  
  def update
    settings = notification_settings_params
    
    if current_user.update(notification_settings: settings)
      render json: {
        notification_settings: current_user.notification_settings,
        message: 'Notification settings updated successfully'
      }
    else
      render json: { 
        errors: current_user.errors.full_messages 
      }, status: :unprocessable_entity
    end
  end
  
  private
  
  def notification_settings_params
    params.require(:notification_settings).permit!
  end
  
  def default_settings
    {
      activity_reminders: {
        enabled: true,
        channels: {
          bell: true,
          popup: true,
          email: false,
          sms: false
        }
      },
      lead_reminders: {
        enabled: true,
        channels: {
          bell: true,
          popup: true,
          email: false,
          sms: false
        }
      },
      contact_reminders: {
        enabled: true,
        channels: {
          bell: true,
          popup: true,
          email: false,
          sms: false
        }
      },
      account_reminders: {
        enabled: true,
        channels: {
          bell: true,
          popup: true,
          email: false,
          sms: false
        }
      }
    }
  end
end
