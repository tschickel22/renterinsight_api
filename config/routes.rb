# frozen_string_literal: true
Rails.application.routes.draw do
  namespace :api, defaults: { format: :json } do
    namespace :crm do
      # ==================== LEADS ====================
      resources :leads, only: %i[index show create update destroy] do
        member do
          post :notes
          post :convert, to: 'lead_conversions#convert'
          get  :score, to: 'lead_scores#show'
          post 'score/calculate', to: 'lead_scores#calculate'
        end

        # Activities
        resources :activities, only: %i[index create]

        # AI Insights
        resources :ai_insights, only: %i[index] do
          collection { post :generate }
        end
        # Alternative hyphenated route for AI Insights
        get  'ai-insights', to: 'ai_insights#index'
        post 'ai-insights/generate', to: 'ai_insights#generate'

        # Communications
        resources :communications, only: %i[index create] do
          collection do
            post :send_email
            post :send_sms
          end
        end
        # Alternative routes for communications
        post 'communications/email', to: 'communications#send_email'
        post 'communications/sms', to: 'communications#send_sms'

        # Reminders
        resources :reminders, only: %i[index create destroy] do
          member do
            post :complete
            patch :complete
          end
        end

        # Lead Tasks
        resources :tasks, only: %i[create update destroy], controller: 'lead_tasks'

        # Lead-scoped tags
        get    'tags', to: 'tags#entity_tags_for_lead'
        post   'tags', to: 'tags#assign_to_lead'
        delete 'tags/:tag_id', to: 'tags#remove_from_lead'
      end

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
        member { patch :complete }
      end

      # ==================== LEAD SCORES ====================
      resources :lead_scores, only: [] do
        member do
          get :show
          post :calculate
        end
      end

      # ==================== LEAD CONVERSIONS ====================
      resources :lead_conversions, only: [] do
        member { post :convert }
      end

      # ==================== NURTURE ====================
      namespace :nurture do
        resources :sequences, only: %i[index create update destroy] do
          collection { post :bulk }
          resources :steps, only: %i[index create update destroy]
        end

        resources :enrollments, only: %i[index] do
          collection { post :bulk }
        end

        resources :templates, only: %i[index] do
          collection { post :bulk }
        end
      end

      # ==================== INTAKE ====================
      namespace :intake do
        resources :forms, only: %i[index create update destroy] do
          collection { post :bulk }
        end

        resources :submissions, only: %i[index create] do
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

  # ==================== HEALTH CHECK ====================
  get 'up', to: 'rails/health#show', as: :rails_health_check

  # ==================== ROOT ====================
  root to: proc { [200, {}, ['Renter Insight API']] }
end
