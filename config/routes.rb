# frozen_string_literal: true
Rails.application.routes.draw do
  # Health check
  get 'up', to: 'rails/health#show', as: :rails_health_check

  # Root
  root to: proc { [200, {}, ['Renter Insight API']] }

  # ==================== PUBLIC INTAKE FORMS ====================
  scope path: 'f', module: 'public', as: 'public' do
    get ':public_id', to: 'forms#show', as: :form
    post ':public_id/submit', to: 'forms#submit', as: :form_submit
  end
  
  # API endpoints for public forms (for frontend)
  namespace :api do
    scope path: 'f' do
      get ':public_id', to: '/public/forms#show'
      post ':public_id/submit', to: '/public/forms#submit'
    end
    
    # ==================== V1 API ====================
    namespace :v1 do
      # ==================== NOTES ====================
      resources :notes, only: [:index, :create, :update, :destroy]
      
      # ==================== VEHICLES/INVENTORY ====================
      resources :vehicles do
        collection do
          get :stats
        end
      end
      
      # ==================== QUOTES ====================
      resources :quotes do
        member do
          post :send, to: 'quotes#send_quote'
          post :accept
          post :reject
        end
        
        collection do
          get :stats
          get :export
        end
      end
      
      # Account activity reminders (for marking as sent)
      post 'account_activities/:id/mark_reminder_sent', to: 'account_activities#mark_reminder_sent'
      
      # ==================== CONTACTS ====================
      resources :contacts do
        member do
          post :tags, to: 'contacts#add_tags'
          delete 'tags/:tag_name', to: 'contacts#remove_tag'
          patch :opt_in_email, to: 'contacts#opt_in_email'
          patch :opt_out_email, to: 'contacts#opt_out_email'
          patch :opt_in_sms, to: 'contacts#opt_in_sms'
          patch :opt_out_sms, to: 'contacts#opt_out_sms'
          get :deals
          get :quotes
        end
        
        collection do
          get :stats
          post :bulk_create
        end
        
        # Contact Communications
        resources :communications, controller: 'contact_communications', only: [:index] do
          collection do
            post :email
            post :sms
            post :log
          end
        end
        
        # Contact Activities
        resources :activities, controller: 'contact_activities' do
          member do
            post :complete
            post :cancel
          end
        end
        
        # Contact Nurture
        get 'nurture', to: 'contact_nurture#index'
        post 'nurture/enroll', to: 'contact_nurture#enroll'
        post 'nurture/:enrollment_id/pause', to: 'contact_nurture#pause'
        post 'nurture/:enrollment_id/resume', to: 'contact_nurture#resume'
        post 'nurture/:enrollment_id/unenroll', to: 'contact_nurture#unenroll'
      end
      
      # ==================== ACCOUNTS ====================
      resources :accounts do
        member do
          post :convert_to_customer
          post :tags, to: 'accounts#add_tags'
          delete 'tags/:tag_name', to: 'accounts#remove_tag'
          get :deals
        end
        
        collection do
          get :stats
          get :industries
          get :export
          post :convert_lead
          post :bulk_update
        end
        
        # Nested resources for accounts
        resources :contacts, only: [:index], controller: 'contacts'
        resources :activities, controller: 'account_activities' do
          member do
            post :complete
            post :cancel
          end
          collection do
            get :reminders
          end
        end
        resources :messages, controller: 'account_messages', only: [:index, :create]
        
        # Account Communications
        resources :communications, controller: 'account_communications', only: [:index] do
          collection do
            post :email
            post :sms
            post :log
          end
        end
        
        member do
          get :insights
          get :score
        end
      end
    end
  end

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
          post :convert
          
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
        resources :forms do
          collection { post :bulk }
        end

        resources :submissions, only: %i[index create] do
          collection { post :bulk }
        end
      end
    end

    # ==================== COMPANY SETTINGS ====================
    namespace :company do
      resource :settings, only: %i[show update] do
        post :test_email, on: :collection
        post :test_sms, on: :collection
      end
    end

    # ==================== PLATFORM SETTINGS ====================
    namespace :platform do
      resource :settings, only: %i[show update] do
        post :test_email, on: :collection
        post :test_sms, on: :collection
      end
      
      # ==================== PLATFORM COMMUNICATIONS ====================
      # Unified communications API for all entity types
      get 'communications/:entity_type/:entity_id/history', to: 'communications#history'
      post 'communications/email', to: 'communications#email'
      post 'communications/sms', to: 'communications#sms'
      
      # Communication templates
      get 'communications/templates', to: 'communications#index_templates'
      post 'communications/templates', to: 'communications#create_template'
      get 'communications/templates/:id', to: 'communications#show_template'
      patch 'communications/templates/:id', to: 'communications#update_template'
      put 'communications/templates/:id', to: 'communications#update_template'
      delete 'communications/templates/:id', to: 'communications#destroy_template'
    end
  end
  # Phase 5A - Unified Login Authentication
  namespace :api do
    namespace :auth do
      post 'login', to: 'login#create'
      post 'logout', to: 'login#destroy'
      post 'refresh', to: 'login#refresh'
      get 'verify', to: 'login#verify'
      get 'me', to: 'login#me'
      
      # Password Reset
      post 'request_password_reset', to: 'password_reset#request_reset'
      post 'verify_reset_token', to: 'password_reset#verify_token'
      post 'reset_password', to: 'password_reset#reset_password'
      
      # Magic Link
      post 'request_magic_link', to: 'magic_link#request_magic_link'
      get 'verify_magic_link', to: 'magic_link#verify_magic_link'
    end
  end

  # Phase 4A & 4B - Portal
  namespace :api do
    namespace :portal do
      # Phase 4A - Authentication
      post 'auth/login', to: 'auth#login'
      post 'auth/request_magic_link', to: 'auth#request_magic_link'
      post 'auth/magic-link', to: 'auth#request_magic_link'
      get 'auth/verify_magic_link', to: 'auth#verify_magic_link'
      post 'auth/request_reset', to: 'auth#request_reset'
      post 'auth/forgot-password', to: 'auth#forgot_password'
      post 'auth/reset-password', to: 'auth#reset_password'
      patch 'auth/reset_password', to: 'auth#reset_password'
      get 'auth/profile', to: 'auth#profile'
      
      # Phase 4B - Quote Management
      resources :quotes, only: [:index, :show] do
        member do
          patch :accept
          patch :reject
        end
      end
      
      # Phase 4C - Communications
      resources :communications, only: [:index, :show, :create] do
        member do
          patch :mark_as_read
        end
      end
      get 'communications/threads', to: 'communications#threads'
      post 'communications/:thread_id/reply', to: 'communications#create'
      
      # Phase 4E - Document Management
      resources :documents, only: [:index, :show, :create, :destroy] do
        member do
          get :download
        end
      end

      # Phase 4D - Communication Preferences
      get 'preferences', to: 'preferences#show'
      patch 'preferences', to: 'preferences#update'
      get 'preferences/history', to: 'preferences#history'
    end
    
    # Admin Impersonation (Testing Only)
    namespace :admin do
      # Phase 5B - Admin Documents Management
      resources :documents, only: [:index, :show, :create, :update, :destroy] do
        member do
          get :download
        end
      end
      
      # Admin Buyers List (for dropdown)
      resources :buyers, only: [:index]
      
      # Impersonation routes (must be last to avoid conflicts)
      post 'impersonate', to: 'impersonation#create'
      get 'impersonate/buyers', to: 'impersonation#buyers'
    end
  end

end
