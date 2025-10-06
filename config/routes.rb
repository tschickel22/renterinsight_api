# frozen_string_literal: true
Rails.application.routes.draw do
  namespace :api do
    namespace :crm do
      resources :leads, only: [:index, :show, :create, :update] do
        resources :activities, only: [:index, :create]
        resources :ai_insights, only: [:index]
        resources :reminders, only: [:index, :create, :destroy] do
          member { post :complete }
        end
        resources :communications, only: [:index] do
          collection do
            post :send_email
            post :send_sms
            post :create_log
          end
        end
        member do
          get  :score
          post :score, action: :recalculate_score
          post :convert
        end
        # Lead-scoped tags (FE uses these)
        get    'tags',         to: 'tags#entity_tags_for_lead'
        post   'tags',         to: 'tags#assign_to_lead'
        delete 'tags/:tag_id', to: 'tags#remove_from_lead'
      end
      
      # Tag catalog + generic helpers
      resources :tags, only: [:index, :create, :update, :destroy] do
        collection do
          post :assign
          get  'entity/:entity_type/:entity_id', to: 'tags#entity_tags'
        end
      end
      delete 'tags/assignments/:id', to: 'tags#remove_assignment'
      
      # Reminders with complete action (for non-lead-scoped completion)
      resources :reminders, only: [] do
        member do
          patch :complete
        end
      end
      
      # Sources with stats endpoint
      resources :sources, only: [:index, :create, :update, :destroy] do
        member do
          get :stats
        end
      end
    end
  end
end
