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
    resources :tenant_payments, only: %i[new create]
    resources :tenancy_parties, only: %i[new create edit update destroy]
    resources :rent_terms, only: %i[new create]
  end

  resources :expenses
  resources :tenant_payments
  resources :tenant_charges, only: %i[show destroy]
  resources :scheduled_rents, only: %i[index show]
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
