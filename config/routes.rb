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
    resource :security_deposit, only: %i[new create show edit update] do
      post :receive
      post :refund
      post :apply
    end
  end

  resources :security_deposit_transactions, only: %i[show] do
    member do
      get :correction
      post :correct
      post :void
    end
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
  resources :source_documents, only: %i[new create destroy] do
    member do
      get :download
      post :retry
    end
  end
  resources :imported_transactions, only: %i[index show update destroy] do
    member do
      post :confirm
    end
  end

  resource :session
  resources :passwords, param: :token

  get "up" => "rails/health#show", as: :rails_health_check
end
