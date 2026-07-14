# frozen_string_literal: true

module SolidGcp
  # Receives Cloud Tasks / Cloud Scheduler pushes. API-style (CSRF skipped),
  # OIDC-verified, JSON body. Maps Receiver outcomes to HTTP statuses.
  class TasksController < ActionController::Base
    skip_forgery_protection

    before_action :verify_oidc!

    # POST /perform
    def perform
      Receiver.receive(envelope)
      head :no_content
    rescue SolidGcp::NotReady
      head :service_unavailable
    end

    # POST /launch
    def launch
      CloudRunJobLauncher.launch(envelope)
      head :no_content
    rescue StandardError => e
      Rails.error.report(e, handled: true) if defined?(Rails) && Rails.respond_to?(:error)
      head :service_unavailable
    end

    # POST /sweep
    def sweep
      Sweep.run
      head :no_content
    end

    # POST /recurring/:key
    def recurring
      return head(:not_found) unless Recurring.enqueue(params[:key])

      head :no_content
    end

    private

    def envelope
      @envelope ||= JSON.parse(request.body.read)
    end

    def verify_oidc!
      return if SolidGcp.oidc_verifier.verify(bearer_token)

      head :unauthorized
    end

    def bearer_token
      header = request.headers["Authorization"].to_s
      header.split(" ", 2).last if header.start_with?("Bearer ")
    end
  end
end
