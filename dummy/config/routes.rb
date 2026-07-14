Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Solid GCP engine — MUST be mounted exactly at /solid_gcp. Cloud Tasks /
  # Cloud Scheduler push to /solid_gcp/perform|launch|sweep|recurring/:key.
  mount SolidGcp::Engine => "/solid_gcp"

  # Minimal dashboard: recent JobRuns + failed jobs, buttons to enqueue demos.
  root "dashboard#index"
  post "demos/:job" => "dashboard#enqueue", as: :enqueue_demo
  post "failed_jobs/:id/retry" => "dashboard#retry_failed", as: :retry_failed_job

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
