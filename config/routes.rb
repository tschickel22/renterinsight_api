Rails.application.routes.draw do
  namespace :api do
    namespace :crm do
      # Full CRUD for FE saves
      resources :sources, only: [:index, :create, :update, :destroy] do
        # provide both collection and member stats so FE variants won't 404
        collection { get :stats }
        member     { get :stats }
      end

      resources :leads, only: [:index, :create, :update, :destroy]

      namespace :nurture do
        resources :sequences,   only: [:index] do
          collection { post :bulk }
        end
        resources :enrollments, only: [:index] do
          collection { post :bulk }
        end
      end
    end
  end
end
