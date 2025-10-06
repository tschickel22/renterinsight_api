# frozen_string_literal: true

Rails.application.routes.draw do
  namespace :api, defaults: { format: :json } do
    namespace :crm do
      resources :leads, only: %i[index show create update] do
        resources :activities,  only: %i[index create]
        resources :ai_insights, only: %i[index]
        resources :reminders,   only: %i[index create destroy] do
          member { post :complete }
        end

        # Lead-scoped tags
        get    'tags',         to: 'tags#entity_tags_for_lead'
        post   'tags',         to: 'tags#assign_to_lead'
        delete 'tags/:tag_id', to: 'tags#remove_from_lead'
      end

      # Tag catalog + helpers
      resources :tags, only: %i[index create update destroy] do
        collection do
          post :assign
          get  'entity/:entity_type/:entity_id', to: 'tags#entity_tags'
        end
      end
      delete 'tags/assignments/:id', to: 'tags#remove_assignment'

      # Reminders (non-lead-scoped completion)
      resources :reminders, only: [] do
        member { patch :complete }
      end

      # -------- Nurture namespace (to match FE calls) --------
      namespace :nurture do
        resources :sequences, only: %i[index create update destroy] do
          collection { post :bulk }   # POST /api/crm/nurture/sequences/bulk
        end

        resources :enrollments, only: %i[index] do
          collection { post :bulk }   # POST /api/crm/nurture/enrollments/bulk
        end

        resources :templates, only: %i[index] do
          collection { post :bulk }   # POST /api/crm/nurture/templates/bulk
        end
      end
      # -------------------------------------------------------
    end
  end
end
