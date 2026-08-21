Rails.application.routes.draw do
  root "dashboards#index"
  get "dashboards/index"

  resources :properties do
    resources :rentable_units
    resources :expenses, only: %i[new create]

    member do
      get :schedule_e
      get :schedule_e_pdf
    end
  end

  resources :parties

  resources :tenancies do
    resources :receipts, only: %i[new create]
    resources :charges, only: %i[new create]
    resources :tenancy_parties, only: %i[new create edit update destroy]
    resources :rent_terms, only: %i[new create]
  end

  resources :expenses, only: %i[index show new create] do
    resources :reimbursements, only: %i[new create], controller: "expense_reimbursements"
    member do
      get :correction
      post :correct
      post :void
    end
  end
  resources :receipts, only: %i[index show new create] do
    member do
      get :correction
      post :correct
      post :void
    end
  end
  resources :charges, only: %i[show] do
    member do
      post :void
    end
  end
  resources :payment_ingestions do
    member do
      post :confirm
      get :download
    end
  end
  resources :payment_documents, only: %i[destroy]

  resource :session
  resources :passwords, param: :token

  get "up" => "rails/health#show", as: :rails_health_check
end
