# frozen_string_literal: true

Rails.application.routes.draw do
  # Simple health check (optional)
  get "/up", to: "rails/health#show", as: :rails_health_check

  namespace :api do
    namespace :crm do
      # ===== Sources =====
      resources :sources, only: [:index, :create, :update, :destroy] do
        get :stats, on: :member
      end

      # ===== Leads (core) =====
      resources :leads, only: [:index, :create, :update, :destroy], param: :id do
        post :notes, on: :member

        # Tasks (already present in your app)
        resources :tasks, only: [:create, :update, :destroy], controller: "lead_tasks"

        # --- Activities ---
        get  'activities',           to: 'activities#index'
        post 'activities',           to: 'activities#create'

        # --- AI Insights ---
        get  'ai_insights',          to: 'ai_insights#index'
        post 'ai_insights/generate', to: 'ai_insights#generate'

        # --- Reminders ---
        get  'reminders',            to: 'reminders#index'
        post 'reminders',            to: 'reminders#create'

        # --- Lead Scoring ---
        get  'score',                to: 'lead_scores#show'
        post 'score/calculate',      to: 'lead_scores#calculate'

        # --- Tags assigned to this lead ---
        get  'tags',                 to: 'tags#entity_tags'

        # --- Convert Lead ---
        post 'convert',              to: 'lead_conversions#convert'

        # --- Communications (lead-scoped) ---
        get  'communications',              to: 'communications#index'
        # Map history to the same payload; keeps FE happy even if code reload lags
        get  'communications/history',      to: 'communications#index'
        get  'communications/settings',     to: 'communications#settings'
        post 'communications/send_email',   to: 'communications#send_email'
        post 'communications/send_sms',     to: 'communications#send_sms'
        post 'communications/log',          to: 'communications#log'

      end

      # Single insight actions
      patch 'ai_insights/:id/mark_read', to: 'ai_insights#mark_read'

      # Standalone reminders actions
      resources :reminders, only: [:destroy] do
        patch :complete, on: :member
      end

      # Global tag catalog + assignment helpers
      resources :tags, only: [:index, :create, :update, :destroy]
      post   'tags/assign',             to: 'tags#assign'
      delete 'tags/assignments/:id',    to: 'tags#remove_assignment'

      # ===== Nurture =====
      namespace :nurture do
        resources :sequences, only: [:index, :create, :update, :destroy] do
          collection { post :bulk }
          resources :steps, only: [:index, :create, :update, :destroy]
        end
        resources :enrollments, only: [:index] do
          collection { post :bulk }
        end
        resources :templates, only: [:index] do
          collection { post :bulk }
        end
      end

      # ===== Intake (used by your FE) =====
      namespace :intake do
        resources :forms, only: [:index] do
          collection { post :bulk }
        end
        resources :submissions, only: [:index] do
          collection { post :bulk }
        end
      end
    end
  end
end
