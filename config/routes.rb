# frozen_string_literal: true
Rails.application.routes.draw do
  # Health check
  get 'up', to: 'rails/health#show', as: :rails_health_check

  # Root
  root to: proc { [200, {}, ['Renter Insight API']] }

  # Mount ActionCable for WebSocket notifications
  mount ActionCable.server => '/cable'

  namespace :api, defaults: { format: :json } do
    namespace :crm do
      # ==================== SOURCES ====================
      resources :sources, only: %i[index create update destroy] do
        member { get :stats }
        collection { get :stats }
      end

      # ==================== TAGS ====================
      resources :tags, only: %i[index create update destroy] do
        collection do
          post :assign
          get 'entity/:entity_type/:entity_id', to: 'tags#entity_tags'
        end
      end
      delete 'tags/assignments/:id', to: 'tags#remove_assignment'

      # ==================== AI INSIGHTS (Non-Lead-Scoped) ====================
      resources :ai_insights, only: [] do
        member { post :mark_read }
      end

      # ==================== REMINDERS (Non-Lead-Scoped) ====================
      resources :reminders, only: [] do
        member do
          post :complete
          patch :complete
        end
      end

      # ==================== LEAD SCORES ====================
      resources :lead_scores, only: [] do
        collection do
          get ':lead_id', to: 'lead_scores#show'
          post ':lead_id/calculate', to: 'lead_scores#calculate'
        end
      end

      # ==================== COMMUNICATIONS (Non-Lead-Scoped) ====================
      # These routes accept lead_id in the request body
      post 'communications/email', to: 'communications#email'
      post 'communications/sms', to: 'communications#sms'

      # ==================== LEADS ====================
      resources :leads, only: %i[index show create update destroy] do
        # Member routes (actions on specific lead)
        member do
          # Notes
          post :notes
          
          # Conversion
          post :convert, to: 'lead_conversions#convert'
          
          # Scoring
          get :score, to: 'lead_scores#show'
          post 'score/calculate', to: 'lead_scores#calculate'
        end

        # Nested resources
        
        # Activities
        resources :activities, only: %i[index create update destroy]

        # Communications
        resources :communications, only: %i[index create] do
          collection do
            post :send_email
            post :send_sms
          end
        end
        # Alternative communication routes
        post 'communications/email', to: 'communications#send_email'
        post 'communications/sms', to: 'communications#send_sms'

        # AI Insights
        resources :ai_insights, only: %i[index] do
          collection { post :generate }
        end
        # Alternative hyphenated routes for AI Insights
        get 'ai-insights', to: 'ai_insights#index'
        post 'ai-insights/generate', to: 'ai_insights#generate'

        # Reminders
        resources :reminders, only: %i[index create update destroy] do
          member do
            post :complete
            patch :complete
          end
        end

        # Tasks
        resources :tasks, only: %i[create update destroy], controller: 'lead_tasks'
        
        # Lead Activities (unified activities)
        resources :lead_activities, only: %i[index show create update destroy] do
          member do
            post :complete
            post :cancel
          end
        end

        # Tags (lead-scoped)
        get 'tags', to: 'tags#entity_tags_for_lead'
        post 'tags', to: 'tags#assign_to_lead'
        delete 'tags/:tag_id', to: 'tags#remove_from_lead'
      end

      # ==================== NURTURE ====================
      namespace :nurture do
        resources :sequences, only: %i[index create update destroy] do
          collection { post :bulk }
          resources :steps, only: %i[index create update destroy]
        end

        resources :enrollments, only: %i[index create update destroy] do
          collection { post :bulk }
        end

        resources :templates, only: %i[index create update destroy] do
          collection { post :bulk }
        end
      end

      # ==================== INTAKE ====================
      namespace :intake do
        resources :forms, only: %i[index create update destroy] do
          collection { post :bulk }
        end

        resources :submissions, only: %i[index create destroy] do
          collection { post :bulk }
        end
      end
    end

    # ==================== COMPANY SETTINGS ====================
    namespace :company do
      resource :settings, only: %i[show update]
    end

    # ==================== PLATFORM SETTINGS ====================
    namespace :platform do
      resource :settings, only: %i[show update]
    end
  end
end
