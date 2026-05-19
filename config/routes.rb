Rails.application.routes.draw do
  get "dashboards/index"
  resources :expenses
  resources :tenant_payments
  resources :tenant_charges, only: [ :show, :destroy ]
  resources :scheduled_rents
  resources :leases do
    resources :tenant_payments, only: [ :new, :create ]
    post :generate_scheduled_rents, on: :member
  end
  resources :tenants
  resources :rental_properties do
    resources :expenses, only: [ :new, :create ]
    member do
      get :schedule_e
      get :schedule_e_pdf
    end
  end
  resource :session
  resources :passwords, param: :token

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  root "dashboards#index"
end
