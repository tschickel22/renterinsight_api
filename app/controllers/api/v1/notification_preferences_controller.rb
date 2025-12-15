# app/controllers/api/v1/notification_preferences_controller.rb
class Api::V1::NotificationPreferencesController < ApplicationController
  before_action :set_company_scope
  
  def index
    # Get or create all preferences for user
    preferences = []
    grouped = {}
    
    Notification::TYPES.each do |type, config|
      pref = NotificationPreference.get_or_create_for(current_user, type)
      preferences << pref
      
      grouped[config[:category]] ||= []
      grouped[config[:category]] << pref
    end
    
    render json: {
      preferences: preferences.as_json,
      grouped: grouped.transform_values { |prefs| prefs.as_json },
      available_types: Notification::TYPES.keys.map(&:to_s),
      categories: Notification::TYPES.values.map { |t| t[:category] }.uniq
    }
  end
  
  def show
    preference = current_user.notification_preferences.find(params[:id])
    render json: preference
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Preference not found' }, status: :not_found
  end
  
  def create
    preference = current_user.notification_preferences.build(preference_params)
    
    if preference.save
      render json: preference, status: :created
    else
      render json: { errors: preference.errors }, status: :unprocessable_entity
    end
  end
  
  def update
    preference = current_user.notification_preferences.find(params[:id])
    
    if preference.update(preference_params)
      render json: preference
    else
      render json: { errors: preference.errors }, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Preference not found' }, status: :not_found
  end
  
  def bulk_update
    preferences_data = params[:preferences] || []
    updated = 0
    errors = []
    
    preferences_data.each do |pref_data|
      begin
        if pref_data[:id]
          # Update existing
          pref = current_user.notification_preferences.find(pref_data[:id])
          if pref.update(pref_data.permit(:in_app_enabled, :email_enabled, :sms_enabled, :frequency))
            updated += 1
          else
            errors << { id: pref.id, errors: pref.errors }
          end
        elsif pref_data[:notification_type]
          # Create or update by notification_type
          pref = NotificationPreference.get_or_create_for(current_user, pref_data[:notification_type])
          if pref.update(pref_data.permit(:in_app_enabled, :email_enabled, :sms_enabled, :frequency))
            updated += 1
          else
            errors << { notification_type: pref_data[:notification_type], errors: pref.errors }
          end
        end
      rescue => e
        errors << { error: e.message }
      end
    end
    
    render json: {
      success: true,
      updated: updated,
      errors: errors
    }
  end
  
  def update_category
    category = params[:category]
    update_params = params[:notification_preference] || {}
    
    # Get all preferences for this category
    preferences = current_user.notification_preferences.by_category(category)
    
    # If no preferences exist, create them
    if preferences.empty?
      Notification::TYPES.select { |_, config| config[:category] == category }.each do |type, _|
        NotificationPreference.get_or_create_for(current_user, type)
      end
      preferences = current_user.notification_preferences.by_category(category)
    end
    
    # Update all preferences in category
    updated = 0
    preferences.each do |pref|
      if pref.update(update_params.permit(:in_app_enabled, :email_enabled, :sms_enabled, :frequency))
        updated += 1
      end
    end
    
    render json: {
      success: true,
      updated: updated,
      message: "Updated #{updated} preference(s) in #{category} category"
    }
  end
  
  def reset_defaults
    # Delete all existing preferences
    current_user.notification_preferences.destroy_all
    
    # Recreate with defaults
    preferences = []
    Notification::TYPES.each do |type, _|
      pref = NotificationPreference.get_or_create_for(current_user, type)
      preferences << pref
    end
    
    render json: {
      success: true,
      message: 'All preferences reset to defaults',
      preferences: preferences.as_json
    }
  end
  
  private
  
  def preference_params
    params.require(:notification_preference).permit(
      :notification_type,
      :category,
      :in_app_enabled,
      :email_enabled,
      :sms_enabled,
      :frequency,
      :respect_quiet_hours,
      :quiet_hours_start,
      :quiet_hours_end
    )
  end
end
